#!/usr/bin/env bash
# scripts/preflight.sh —— 开工前预检（任何接手者的第一步）
#
# 判定：全部 [ OK ] 才继续；任何 [FAIL] → 把原文报告 dispatcher，不要"先干着看"。
# 检查项：命令齐备 / gh 登录 / cwd 与仓库形态 / 工作区 / 远端唯一 / 作者与合并身份互不相同 /
#         作者凭据 scope 与最小权限 / **工作区内不得存在任何凭据文件**/
#         评审凭据在**工作区之外**（不读其内容）/
#         线上规则集 == 仓库内定义 / 每个必需 context 都有工作流 job / **项目测试套件接线**（tests/ 存在 → tests/run.sh 必须存在且可执行；约定 exit 0 = 通过）/
#         **CODEOWNERS 完整性**（每个 owner 是协作者且有 push、评审身份是 `*` 的 owner、
#         合并身份是协作者 —— 防 require_code_owner_review 永久锁死；开关取值以**线上实测**为准）/
#         机器消费与 **Issue 表单预置**的标签存在（判据 LABEL_ASSERT，与 ci/test 同一段文本）/
#         **`.github/` 内链接的 slug == 当前仓库 slug**（P6：防复制到别处后忘改，判据 = gh repo view）/
#         **并发模型**（#159，第 3、4 组；#169 修假红）：① R1 **单写者锁**——本 clone 若已被另一个写者占用
#         → `[FAIL]`，但"占用"的判据是**写者标识匹配**（pid 存活 **且** cmd/起始时间逐字一致）：pid 会被
#         复用，存活**不足以**证明写者还在（#169）；标识不匹配 / 不可核 = 陈旧锁 → **自动接管并打印原因**
#         （锁在**工作区之外**，判据 WRITER_LOCK_ASSERT）；② R2 **当前分支必须归属一个在途 Issue**
#         （`status/in-progress` **或** `status/in-review`——"交付后待评审"是合法运行点，见 #169）；
#         ③ R3 在途 `in-progress` **>1 仍是 `[WARN]`**——并行**允许**，前提是各自独立 clone
#         （模型见 references/orchestration.md 的并发模型一节）。
#
# 退出码：0 全部通过；1 存在未通过项（每项都给出可行动的修复提示）

set -eu

# 作者凭据默认在**工作区之外**；**禁止**指回工作区内路径（工作区内的凭据 = 作者可读）。
# 写法与 review.sh 的评审凭据一致。
DEVELOPER_PAT_FILE="${DEVELOPER_PAT_FILE:-${HOME}/.config/pm4gh/developer.pat}"
# 评审凭据默认在**工作区之外**：工作区内的评审凭据 = 作者可读，独立评审只剩名义。
# 本脚本对它只做**内容无关**的判据（在不在工作区内 / 存在否 / 权限 / 是否入库）——
# 作者不得读取其他身份的凭据内容（SKILL.md §5），评审身份由 W6 `review.sh` 用凭据自身判定。
REVIEWER_PAT_FILE="${REVIEWER_PAT_FILE:-${HOME}/.config/pm4gh/reviewer.pat}"
RULESET_FILE="${RULESET_FILE:-.github/rulesets/main-protection.json}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# ── R1 单写者锁（#159；模型见 references/orchestration.md 的并发模型一节）────────────────
# **必须**落在工作区之外：锁放进仓库会同时踩三处 —— `git add` / 凭据与「工作区干净」断言 /
#   本脚本自己的工作区判据；且工作区内的锁会被当成未提交改动。默认与凭据同目录（`$HOME/.config/pm4gh`）。
# 键 = **clone 的物理根路径**（不是 slug）：「并行 = 各自独立 clone」，若按 slug 建锁，另一个 clone 的
#   **合法并行写者**会被误判成「占用」（与 R3 的「并行允许」直接矛盾）。
LOCK_DIR="${PM4GH_LOCK_DIR:-${HOME}/.config/pm4gh/locks}"
# 锁龄阈值（分钟）：#169 起**只用于接管报文里标注「锁龄偏大」**，不再是接管的前置条件 ——
#   写者标识不匹配 / 不可核 **即**判陈旧（拿"读不到身份"当"是别人"正是 #169 的假红病灶）。
LOCK_STALE_MINUTES="${PM4GH_LOCK_STALE_MINUTES:-120}"
# 这 5 个字符串是**必需检查的 context**（= 工作流里 job 的 name），一个字都不能差。
REQUIRED_EXPECTED="ci/lint ci/test policy/linked-issue policy/branch-name policy/template"

# ── 规则集全量比对判据（本仓库**唯一**的一份实现）──────────────────────────
# **必须**做一整份 diff，**禁止**挑字段比对：挑字段会让线上多出的键
# （`require_extra_approval_for_unattributed_changes` / `required_reviewers` 一类）静默通过。
# 本判据把线上与文件都投影成同一个规范形（canonical form）后逐字比较：
#   ① 剔除文件内文档键（`_comment*`）与服务端只读元数据（id/node_id/source/...）；
#   ② 其余**全量键**参与：缺键、多键、值不同都会让两个字符串不同；
#   ③ 只做排序（rules 按 type、required_status_checks 按 context），不做任何取值裁剪。
# 同一段文本也出现在 .github/workflows/required-checks.yml 的 ci/test 步骤里，由 ci/test
# 断言两处**逐字一致** —— 比对方式只有这一套，不允许出现第二套。
# RULESET_CANON_JQ:BEGIN
RULESET_CANON_JQ='def canon: with_entries(select(.key|startswith("_comment")|not)) | del(.id,.node_id,.source_type,.source,.created_at,.updated_at,.current_user_can_bypass,._links) | .conditions.ref_name.include = ((.conditions.ref_name.include // [])|sort) | .conditions.ref_name.exclude = ((.conditions.ref_name.exclude // [])|sort) | .bypass_actors = ((.bypass_actors // [])|sort_by(.actor_id|tostring)) | .rules = ((.rules // []) | map(if (.type == "required_status_checks" and .parameters) then .parameters.required_status_checks = ((.parameters.required_status_checks // [])|sort_by(.context)) else . end) | sort_by(.type)); canon'
# RULESET_CANON_JQ:END

# ── 标签存在性判据：机器消费 + Issue 表单预置（本仓库**唯一**的一份实现）────────
# **必须**断言这些标签存在：标签是**仓库级对象**，仓库里没有清单也没有断言。而 `status.sh`
# 的 --add-label 遇到不存在的标签会**直接失败**（把 Issue 留在「零 status/* 标签」的中间态）；
# `start.sh` 靠 `type/*` 推导分支类型，缺标签会**静默**退化；Issue 表单的 `labels:` 指向不存在的
# 标签时，**用该表单建单直接失败**（D2 的假绿：预检全绿而表单不可用）。本判据只断言存在性，
# 不新增任何必需检查、不改线上标签。
# 同一段文本也出现在 .github/workflows/required-checks.yml 的 ci/test 步骤里，由 ci/test 断言
# 两处**逐字一致**（并带反向样本，证明判据本身不是空断言）—— 判据只有这一套。
# LABEL_ASSERT:BEGIN
#   ① 机器消费（手写清单 MACHINE_LABELS）：status/* ×3（status.sh 迁移）+ type/* ×4（start.sh 推导）；
#   ② Issue 表单预置（**从模板解析，不手抄**）：.github/ISSUE_TEMPLATE/*.yml 里每个 `labels:` 的值。
# fail-closed：模板解析不出任何标签 → 判据报错；**不许**"解析不到就算通过"。
MACHINE_LABELS="status/ready status/in-progress status/in-review type/bug type/hotfix type/spike type/chore"
TEMPLATE_GLOB=".github/ISSUE_TEMPLATE/*.yml"

# 从模板解析全部 `labels:` 值：flow 形式（labels: ["a", "b"]）与块序列（labels: 换行 "- a"）都支持。
# 解析不出任何标签（模板缺失 / 没有顶层 labels: 键 / 值认不出）→ 非零退出 + 原因写 stderr。
template_labels() {
  awk '
    BEGIN { sq = sprintf("%c", 39); inblk = 0; keys = 0; got = 0; keygot = 0; bad = 0 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function err(m) { printf "标签判据：%s\n", m > "/dev/stderr"; bad++ }
    function emit(v,   n, i, a, t, c) {
      gsub(/[]["]/, "", v); gsub(sq, "", v)
      n = split(v, a, ","); c = 0
      for (i = 1; i <= n; i++) { t = trim(a[i]); if (t != "") { print t; got++; c++ } }
      keygot += c
      if (c == 0) err("labels: 键的值解析不出标签")
    }
    function close_key() { if (inblk && keygot == 0) err("块序列形式的 labels: 键解析不出标签"); inblk = 0 }
    {
      if (inblk) {
        if ($0 ~ /^[ \t]+-[ \t]/) { v = $0; sub(/^[ \t]+-[ \t]+/, "", v); sub(/[ \t]+#.*$/, "", v); emit(v); next }
        close_key()
      }
      if ($0 ~ /^labels[ \t]*:/) {
        close_key(); keys++; keygot = 0
        v = $0; sub(/^labels[ \t]*:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
        if (trim(v) != "") emit(v); else inblk = 1
      }
    }
    END {
      close_key()
      if (keys == 0) err("模板里没有顶层的 labels: 键（Issue 表单格式不对？）")
      if (got == 0) err("未从模板解析出任何标签")
      if (bad > 0) exit 4
    }
  ' $TEMPLATE_GLOB
}

assert_machine_labels() {
  tpl="$(template_labels 2>&1)" || { printf '[FAIL] 表单预置标签的解析判据失败：\n%s\n' "$tpl" >&2; return 1; }
  required="$(printf '%s\n%s\n' "$MACHINE_LABELS" "$tpl" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  missing=""
  for l in $required; do
    grep -qxF "$l" <<<"${1:-}" || missing="${missing} ${l}"
  done
  if [ -n "$missing" ]; then
    printf '[FAIL] 标签在平台上不存在：%s\n' "$missing" >&2
    printf '       后果：status.sh 迁移直接失败 / start.sh 静默退化 / 用 Issue 表单建单直接失败。标签是仓库级对象 —— 缺就建：gh label create "<name>" -R <slug>，不要靠删断言绕过\n' >&2
    return 1
  fi
  printf '[ OK ] 机器消费与表单预置的标签全部存在（%s）\n' "$required"
  return 0
}
# LABEL_ASSERT:END

fail=0
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
bad()  { printf '[FAIL] %s\n' "$*" >&2; fail=$((fail + 1)); }
info() { printf '\n== %s ==\n' "$*"; }

# 取某凭据文件对应的登录名（不打印凭据本身）
login_via_pat() {
  [ -s "${1:-}" ] || return 0
  GH_TOKEN="$(cat "$1")" gh api user --jq .login 2>/dev/null || true
}

# classic PAT 的 OAuth scope 列表（官方响应头 x-oauth-scopes，逗号 + 空格分隔）
scopes_via_pat() {
  [ -s "${1:-}" ] || return 0
  curl -sS -I -H "Authorization: token $(cat "$1")" https://api.github.com/user 2>/dev/null \
    | grep -i '^x-oauth-scopes:' \
    | sed -E 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//' \
    | tr -d '\r' | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' || true
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || printf '?'
}

# ── 工作区判据────────────────────────────────────────
# WORKSPACE_ASSERT:BEGIN
# 凭据路径是否落在**工作区之内**：工作区内的凭据 = 作者可读，「独立评审」只剩名义。
# 把路径解析成**绝对路径**：父目录存在时用 `cd … && pwd -P`（解析符号链接，如 /tmp → /private/tmp），
# 否则退回词法归一化 —— 路径不存在也要能判定（凭据缺失正是要报的场景）。**不读文件内容**。
# 同一段文本也出现在另一个脚本里（每个脚本自包含，不引共享库），由 ci/test 断言两处**逐字一致**。
physical() {
  d="$(dirname "${1:-}")"; b="$(basename "${1:-}")"
  if [ -d "$d" ]; then
    d="$(cd "$d" && pwd -P)"
    case "$d" in /) printf '/%s\n' "$b" ;; *) printf '%s/%s\n' "$d" "$b" ;; esac
  else
    abspath "${1:-}"
  fi
}

abspath() {
  p="${1:-}"
  case "$p" in /*) : ;; *) p="$(pwd -P)/${p}" ;; esac
  out=""; rest="$p"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) seg="${rest%%/*}"; rest="${rest#*/}" ;;
      *)   seg="$rest"; rest="" ;;
    esac
    case "$seg" in
      ''|.) : ;;
      ..)   out="${out%/*}" ;;
      *)    out="${out}/${seg}" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

# 命中工作区（含仓库根自身）→ 0；否则 1。仓库根取 `git rev-parse --show-toplevel` 的物理路径。
pat_in_workspace() {
  ws_root="$(cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" && pwd -P)"
  case "$(physical "${1:-}")" in
    "$ws_root"|"$ws_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}
# WORKSPACE_ASSERT:END

# ── R1 单写者锁的判据本体（#159；#169 加写者身份核对）────────────────────────
# 一处实现：第 3 组的执行与 owner 文档（references/orchestration.md 的并发模型一节）都指这里。
# 锁内容（`key=value`，一行一个）：pid（获取它的进程）/ branch / slug / clone（物理根路径）/
#   time（epoch 秒，用于算锁龄）/ time_iso（给人看）/ cmd（**写者标识**：实际命令行）/
#   start（**第二判据**：进程起始时间）。#169：**pid 存活不足以证明写者还在** —— pid 会被无关联
#   进程复用（实测：已退出的 preflight 写的 pid 被别人复用 → R1 假红 + R4 拒绝释放留陈旧锁）。
# 释放（R4）在 `scripts/closeout.sh` 与 `scripts/abort.sh`（各自的 release_writer_lock）。
# WRITER_LOCK_ASSERT:BEGIN
lk_clone_id() { printf '%s' "${1:-}" | sed -E 's#^/##; s#[^A-Za-z0-9]+#-#g'; }
lk_path()     { printf '%s/%s.lock\n' "$LOCK_DIR" "$(lk_clone_id "${1:-}")"; }
lk_field()    { grep -m1 "^${2}=" "${1:-}" 2>/dev/null | sed -E "s/^${2}=//" || true; }
# 存活判定用 `kill -0`（bash 内建）：受限环境（如本项目所在的 agent 沙箱）会直接拒绝 `/bin/ps`，
#   而 `kill -0` 仍可用 —— 否则「pid 存活」这一态永远判不出来，R1 会退化成「锁永远陈旧」。
# 边界（如实）：`kill -0` 对**其他用户**的进程会因 EPERM 返回非零（判成「不存在」）；锁由本用户
#   自己写，正常路径不受影响。身份核对（cmd / start）另用 `ps`；`ps` 不可用（受限环境会直接拒绝
#   `/bin/ps`）时两者记空 = **不可核** —— 不可核按陈旧锁处理，**不得**当成「别人的活写者」（假红）。
lk_alive() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}
# 写者标识（#169）= 活进程的实际命令行（`ps -o command=`）；取不到 → 空 = **不可核**。
lk_cmd_of() {
  [ -n "${1:-}" ] || return 0
  ps -p "$1" -o command= 2>/dev/null | tr -d '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-160 || true
}
# 第二判据（#169）= 进程起始时间（`ps -o lstart=`）；防「同样的命令行被重跑」造成的 pid 复用误判。
lk_start_of() {
  [ -n "${1:-}" ] || return 0
  ps -p "$1" -o lstart= 2>/dev/null | tr -d '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' || true
}
# 写者身份核对（#169）：0 = **标识匹配**（确是本流程的写者）；1 = **不匹配 / 不可核**。
#   判据 = ① 锁里的 cmd 非空 **且** 与活进程实际命令行逐字一致；
#          ② 锁里的 start 非空 **且** 与活进程起始时间一致（第一条可能被「同命令行重跑」骗过）。
#   任一为空 / 不符 → 1 ⇒ 调用方按**陈旧锁**处理（接管 / 可释放）—— 这是 #169 的方向性选择：
#   「读不到身份」不等于「是别人的活写者」，宁可接管也不假红。
lk_writer_match() { # $1 = 锁文件；$2 = pid
  lk_m_cmd="$(lk_field "${1:-}" cmd)"
  lk_m_start="$(lk_field "${1:-}" start)"
  [ -n "$lk_m_cmd" ] || return 1
  [ "$(lk_cmd_of "${2:-}")" = "$lk_m_cmd" ] || return 1
  [ -n "$lk_m_start" ] || return 1
  [ "$(lk_start_of "${2:-}")" = "$lk_m_start" ] || return 1
  return 0
}
# 锁目录可否用：能创建**且**能写入探针文件（只在目录里留一个瞬时文件，随即删掉）。
lk_usable() {
  [ -n "${1:-}" ] || return 1
  mkdir -p "$1" 2>/dev/null || return 1
  ( : > "${1}/.lk-probe.$$" ) 2>/dev/null || return 1
  rm -f "${1}/.lk-probe.$$" 2>/dev/null || true
  return 0
}
lk_write() { # $1 = clone 根路径；$2 = 分支；$3 = 记入锁的 pid
  printf 'pid=%s\nbranch=%s\nslug=%s\nclone=%s\ntime=%s\ntime_iso=%s\ncmd=%s\nstart=%s\n' \
    "$3" "${2:-}" "${REPO:-}" "$1" "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(lk_cmd_of "$3")" "$(lk_start_of "$3")" > "$(lk_path "$1")"
}
# 返回 0 = 可以继续（已持有 / 已接管）；1 = 被另一个存活写者占用（调用方负责计数）。
lk_verdict() { # $1 = clone 根路径；$2 = 当前分支
  lk_f="$(lk_path "$1")"
  if [ ! -e "$lk_f" ]; then
    if ! lk_write "$1" "${2:-}" "$$" 2>/dev/null; then
      bad "无法写入单写者锁 ${lk_f}（权限？）—— 无法证明本 clone 只有一个写者"
      return 1
    fi
    ok "已获取本 clone 的单写者锁（pid=$$ branch=${2:-（游离 HEAD）}）：${lk_f}"
    return 0
  fi
  lk_pid="$(lk_field "$lk_f" pid)"
  lk_br="$(lk_field "$lk_f" branch)"
  lk_iso="$(lk_field "$lk_f" time_iso)"
  lk_t="$(lk_field "$lk_f" time)"
  lk_c="$(lk_field "$lk_f" clone)"
  lk_age=-1
  case "$lk_t" in ''|*[!0-9]*) : ;; *) lk_age=$(( ($(date +%s) - lk_t) / 60 )) ;; esac
  lk_age_txt="锁龄未知"
  [ "$lk_age" -ge 0 ] && lk_age_txt="锁龄 ${lk_age} 分钟"
  lk_reason=""
  if ! lk_alive "$lk_pid"; then
    lk_reason="pid ${lk_pid:-（缺失）} 不存在（写者进程已退出）"
  elif lk_writer_match "$lk_f" "$lk_pid"; then
    # pid 存活 **且** 写者标识（cmd + 起始时间）逐字匹配 = 确实是本流程的写者 → 占用，不许接管
    bad "本 clone 已被另一个写者占用（pid=${lk_pid} branch=${lk_br:-未知} 时间=${lk_iso:-未知} 锁=${lk_f}）—— 一个 clone = 一个写者 = 一个 Issue；要**并行**请另开独立 clone（references/orchestration.md 的并发模型一节）。当前分支=${2:-（游离 HEAD）}"
    return 1
  else
    # pid 存活但标识**不匹配 / 不可核** = 疑 pid 复用 → 按陈旧锁处理（#169；不再要求锁龄超阈值）
    lk_reason="pid ${lk_pid} 存活但写者标识**不匹配 / 不可核**（锁里的 cmd/start 与活进程对不上，疑 pid 复用；受限环境里 ps 被拒也会这样）"
    [ "$lk_age" -ge 0 ] && [ "$lk_age" -gt "$LOCK_STALE_MINUTES" ] \
      && lk_reason="${lk_reason}，且 ${lk_age_txt} > ${LOCK_STALE_MINUTES}"
  fi
  # 接管：**打印接管原因**（不静默），并把锁改写成「本轮写者」
  if ! lk_write "$1" "${2:-}" "$$" 2>/dev/null; then
    bad "锁 ${lk_f} 陈旧（${lk_reason}）但无法改写（权限？）—— 无法证明本 clone 只有一个写者"
    return 1
  fi
  [ -n "$lk_br" ] && [ "$lk_br" != "${2:-}" ] \
    && warn "  锁里的 branch=${lk_br} ≠ 当前分支=${2:-（游离 HEAD）}（本 clone 的分支被切过？已接管）"
  [ -n "$lk_c" ] && [ "$lk_c" != "$1" ] \
    && warn "  锁里的 clone=${lk_c} ≠ 本 clone=${1}（clone 被搬移/复制过？已接管）"
  ok "已**自动接管陈旧锁**（原因：${lk_reason}）→ 重写为本轮写者（pid=$$ branch=${2:-（游离 HEAD）}）：${lk_f}"
  return 0
}
# WRITER_LOCK_ASSERT:END

info "1/10 基础命令"
for c in git gh jq awk grep sed curl diff; do
  if command -v "$c" >/dev/null 2>&1; then ok "${c} 可用"; else bad "缺少命令 ${c}，请先安装"; fi
done
printf '  bash：%s\n' "$(bash --version | head -1)"

info "2/10 gh 登录（合并身份 / dispatcher）"
main_login=""
if gh auth status >/dev/null 2>&1; then
  main_login="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login 2>/dev/null || true)"
  if [ -n "$main_login" ]; then ok "gh 已登录：${main_login}"; else bad "gh 已登录但读不到账号（gh api user 失败）"; fi
else
  bad "gh 未登录：运行 gh auth login（合并身份靠它，见 references/identity.md）"
fi

info "3/10 仓库形态与 cwd"
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
REPO=""
# §5 隔离判据的基准：仓库根的**绝对路径**（解析符号链接）
REPO_ROOT="$(pwd -P)"
if [ -z "$toplevel" ]; then
  bad "当前不在 git 仓库内"
else
  REPO_ROOT="$(cd "$toplevel" && pwd -P)"
  cwd_real="$(pwd -P)"
  case "$cwd_real" in
    "$REPO_ROOT"|"$REPO_ROOT"/*) ok "cwd 在仓库内：${cwd_real}" ;;
    *) bad "cwd 不在本仓库内（cwd=${cwd_real}，仓库=${REPO_ROOT}）" ;;
  esac
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    .git|"$toplevel/.git") ok "git common dir = ${common}（非 worktree）" ;;
    *) bad "git common dir=${common} —— 疑似 worktree/隔离副本" ;;
  esac
  wt_count="$(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
  [ "$wt_count" = "1" ] && ok "worktree 数量 1（本 clone 不是共享 git 目录的 worktree）" \
    || bad "检测到 ${wt_count} 个 worktree —— 同一 git 目录的多个 worktree 共享分支/HEAD 状态；要**并行**请各自独立 clone（不要用 worktree）"
  gd="$(git rev-parse --git-dir 2>/dev/null || true)"
  if [ -n "$gd" ] && [ -e "${gd}/index.lock" ]; then
    bad "存在 ${gd}/index.lock —— 可能有另一个 git 进程在跑"
  else
    ok "无 index.lock"
  fi
  [ -f "$RULESET_FILE" ] || bad "缺少规则集定义 ${RULESET_FILE}（是否在仓库根目录？）"
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$REPO" ] && ok "仓库 slug：${REPO}" || bad "无法确定仓库 slug（gh repo view 失败）"

  # ── R1 单写者锁：一个 clone = 一个写者（#159）────────────────────────────────
  # 三态显式（references/exceptions.md §4）：无锁 → 获取；陈旧 → **自动接管并打印原因**（不静默）；
  #   pid 存活且是本流程写者 → `[FAIL]`（另一个写者正在用这个 clone）。
  # 「陈旧」的判定 = pid 不存在，或 pid 存活但**不可核**（锁里的 cmd 与进程实际命令行不符，疑 pid
  #   复用）且锁龄 > N 分钟 —— 两条同时成立才接管，避免把「别人的活进程」误判成陈旧。
  # 判据只在**本 clone 的锁文件**上做：不同 clone = 不同锁文件 ⇒ 并行写者互不误伤（R3）。
  # 锁目录：默认 `$HOME/.config/pm4gh/locks`（与凭据同目录）。默认目录不可写时**回退**到
  #   `/tmp/pm4gh-locks-<uid>` 并**打印回退原因**（受限环境里不能因此变成永久假红）；显式
  #   `PM4GH_LOCK_DIR` 不可写 = 配置错，直接 `[FAIL]`（配置由操作者给定，不做静默替换）。
  #   两个候选都不可写 → `[FAIL]`（真的无法协调，fail-closed）。
  lk_branch="$(git branch --show-current 2>/dev/null || true)"
  lk_fallback_dir="/tmp/pm4gh-locks-$(id -u)"
  lk_ready=0
  if lk_usable "$LOCK_DIR"; then
    lk_ready=1
  elif [ -n "${PM4GH_LOCK_DIR:-}" ]; then
    bad "PM4GH_LOCK_DIR=${LOCK_DIR} 不可用（创建失败 / 不可写）—— 显式指定的锁目录不做回退；换成可写且**工作区之外**的目录"
  elif lk_usable "$lk_fallback_dir"; then
    warn "默认锁目录 ${LOCK_DIR} 不可用（创建 / 写入被拒）→ **回退**到 ${lk_fallback_dir}（同样在**工作区之外**；本次仍受单写者锁约束，锁的路径与原因见下行）"
    LOCK_DIR="$lk_fallback_dir"
    lk_ready=1
  else
    bad "锁目录不可用：默认 ${LOCK_DIR} 与回退 ${lk_fallback_dir} 都创建/写入失败 —— 无法证明本 clone 只有一个写者（修法：把 PM4GH_LOCK_DIR 指向可写且**工作区之外**的目录）"
  fi
  if [ "$lk_ready" = "1" ]; then
    chmod 700 "$LOCK_DIR" 2>/dev/null || true
    lk_verdict "$REPO_ROOT" "$lk_branch" || true
    printf '  本 clone 的单写者锁：%s（键 = clone 物理根路径；生命周期见 references/orchestration.md 的并发模型一节）\n' "$(lk_path "$REPO_ROOT")"
  fi
  # D6：tests/ 存在 = 项目声明了测试套件 → 入口 tests/run.sh 必须存在且可执行。
  # 与 ci/test 的对应 step 同源（那边负责**跑**；这边堵「有 tests/ 却没接线 / 不可执行」——
  # 否则删掉 tests/ 或去掉可执行位即可绕过「跑项目测试」的那一步）。
  # 判据用的是仓库根绝对路径（cwd 允许是仓库子目录）。
  if [ ! -e "${REPO_ROOT}/tests" ]; then
    ok "本项目未声明测试套件（无 tests/ 目录；约定：tests/run.sh，exit 0 = 通过）"
  elif [ ! -d "${REPO_ROOT}/tests" ]; then
    bad "tests 存在但不是目录 —— 约定：测试入口固定为 tests/run.sh（exit 0 = 通过）"
  elif [ ! -f "${REPO_ROOT}/tests/run.sh" ]; then
    bad "tests/ 存在但缺少 tests/run.sh —— 约定：测试入口固定为 tests/run.sh（exit 0 = 通过）；缺入口 = 有测试却没接线门禁"
  elif [ ! -x "${REPO_ROOT}/tests/run.sh" ]; then
    bad "tests/run.sh 缺少可执行位 —— 修复：chmod +x tests/run.sh（ci/test 会运行它）"
  else
    ok "tests/run.sh 存在且可执行 —— ci/test 会运行它（约定 exit 0 = 通过）"
  fi
fi

info "4/10 工作区与远端"
dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ "$dirty" = "0" ] && ok "工作区干净" || warn "工作区有 ${dirty} 处未提交改动 —— 开工前确认归属（不要抹掉他人成果）"
current="$(git branch --show-current 2>/dev/null || true)"
printf '  当前分支：%s\n' "${current:-（游离 HEAD）}"

# ── R2 分支归属：当前分支必须是某个**在途** Issue 的分支（#159；#169 扩到 in-review）────
# 命题：一个 clone = 一个写者 = **一个 Issue**。被另一个写者把工作树切到**别人的分支**上，
# 是本仓库实测发生过的污染源（#144 回归第 2 轮 C 轴）。这里让它在开工前可判定。
# **先枚举合法运行点**（#169 的类级规则：任何新判据必须在**全部合法流程状态**下验证不假红，
#   见 references/exceptions.md §7）—— preflight 会在这些状态下被跑：
#   ① 开工前（W0）→ 基线分支 `${BASE_BRANCH}`：本判据**显式不执行**（`[WARN]`，不计入通过）；
#   ② 实现中 → 切片分支 + Issue `status/in-progress` → **通过**；
#   ③ **交付后待评审** → 同一分支 + Issue `status/in-review` → **通过**（#169 修的假红：deliver.sh
#      交付后 Issue 变 in-review，而作者**仍在分支上等评审**，这是正常流程状态，不是"被切走"）；
#   ④ 返修中 → 同一分支 + Issue 回到 `status/in-progress` → **通过**（与 ② 同一判据）；
#   ⑤ 终止后 → 分支应已删除；分支仍在且 Issue 已关闭（done / canceled）→ `[FAIL]`（保留原意图）；
#   ⑥ 被别人切走 → 分支属**别的** Issue 且该 Issue 非本 clone 的在途项 → `[FAIL]`（保留原意图）。
# 「在途」= Issue **OPEN** 且带 `status/in-progress` **或** `status/in-review`；OPEN 但只有
#   `status/ready` / 无 `status/*`（backlog）= 未开工 → `[FAIL]`；已 CLOSED / 读不到 → `[FAIL]`（fail-closed）。
# 边界（如实，不得过度宣称）：若另一个写者切到的分支**恰好**属于某个在途 Issue，本判据
#   不报（该分支确实合规）—— 这种「同 clone 换分支」由 R1 的单写者锁兜；反之亦然。
case "$current" in
  ""|HEAD)
    bad "游离 HEAD（没有分支）—— 无法证明当前工作归属某个在途 Issue；写者必须站在切片分支上（references/orchestration.md 的并发模型一节）"
    ;;
  "$BASE_BRANCH")
    warn "当前在基线分支 ${BASE_BRANCH}：R2「分支归属在途 Issue」**未执行**（开工前状态，不计入通过）；开工后分支必然形如 <type>/<issue#>-<slug>，此时本判据生效"
    ;;
  *)
    br_num=""
    case "$current" in
      slice/*|fix/*|hotfix/*|spike/*|chore/*) br_num="${current#*/}"; br_num="${br_num%%-*}" ;;
      *) : ;;
    esac
    case "$br_num" in
      ''|*[!0-9]*)
        bad "当前分支 ${current} 既不是基线分支也不是切片分支形态 <type>/<issue#>-<slug> —— 无法证明它归属某个在途 Issue（可能被另一个写者切走了；references/orchestration.md 的并发模型一节）"
        ;;
      *)
        if [ -z "$REPO" ]; then
          bad "仓库 slug 未知，无法判定当前分支 ${current} 是否属于**在途**（in-progress / in-review）的 Issue #${br_num}"
        else
          # 一次读回 state + stateReason + labels：state 判「是否还开着」，stateReason 让 done（COMPLETED）
          # 与 canceled（NOT_PLANNED）在报文里可辨，labels 判「是否在途」。
          br_json="$(gh issue view "$br_num" -R "$REPO" --json state,stateReason,labels 2>/dev/null || true)"
          br_state="$(printf '%s' "$br_json" | jq -r '.state // ""' 2>/dev/null || true)"
          br_sr="$(printf '%s' "$br_json" | jq -r '.stateReason // ""' 2>/dev/null || true)"
          br_labels="$(printf '%s' "$br_json" \
            | jq -r '[.labels[].name | select(startswith("status/"))] | join(",")' 2>/dev/null || true)"
          br_inflight=""
          if grep -qxF "status/in-progress" <<<"$(printf '%s' "$br_labels" | tr ',' '\n')"; then
            br_inflight="status/in-progress"
          fi
          if [ -z "$br_inflight" ] \
            && grep -qxF "status/in-review" <<<"$(printf '%s' "$br_labels" | tr ',' '\n')"; then
            br_inflight="status/in-review"
          fi
          if [ -z "$br_state" ]; then
            bad "当前分支 ${current} 指向 Issue #${br_num}，但读不到该 Issue（不存在 / 无权限？）—— 归属无法证明（fail-closed；references/orchestration.md 的并发模型一节）"
          elif [ "$br_state" != "OPEN" ]; then
            bad "当前分支 ${current} 指向 Issue #${br_num}，但它已 ${br_state}（stateReason=${br_sr:-未知}；done=COMPLETED / canceled=NOT_PLANNED）—— 已关闭的 Issue 不应有在写分支（可能被另一个写者切到了别人的分支）"
          elif [ -n "$br_inflight" ]; then
            ok "分支归属：${current} → Issue #${br_num} 处于 ${br_inflight}（在途：in-progress = 实现/返修，in-review = 交付后待评审；一个 clone = 一个 Issue）"
          else
            bad "当前分支 ${current} 指向 Issue #${br_num}，但它既不是 status/in-progress 也不是 status/in-review（实测标签：${br_labels:-无 status/* = backlog}）—— 本 clone 可能被另一个写者切到了别人的分支（一个 clone = 一个写者 = 一个 Issue）"
          fi
        fi
        ;;
    esac
    ;;
esac

# ── R3 在途切片数：>1 仍是 [WARN]（并行**允许**，前提 = 各自独立 clone）（#159）──────
# 为什么**不**升为 [FAIL]（本片按 dispatcher 定的模型实现）：在途数 >1 可能是**合法的并行**
#   ——每个写者各自独立 clone + 各自 Issue。把它升为 FAIL 会禁止合法并行，且同一 clone 内的
#   互踩已经由 R1（单写者锁）+ R2（分支归属）判定；在途数本身不是「同一 clone 被两个写者占用」
#   的证据（那两个 in-progress 可能落在两个不同 clone 上）。
# 三态（exceptions.md §4）：0/1 → `[ OK ]`；>1 → `[WARN]`（打印且**不计入通过**、不改退出码）；
#   读不到清单 → `[WARN]` 明写「未执行」（**不许**静默跳过）。
if [ -z "$REPO" ]; then
  warn "仓库 slug 未知：在途 in-progress 数量**未统计**（本判据未执行，不计入通过）"
elif ! inprog="$(gh issue list -R "$REPO" --state open --label status/in-progress --limit 100 \
      --json number --jq '.[].number' 2>/dev/null)"; then
  warn "读不到 status/in-progress 的 Issue 清单（gh issue list 失败）—— 在途数量**未统计**（本判据未执行，不计入通过）"
else
  inprog_n="$(printf '%s\n' "$inprog" | grep -c . || true)"
  case "$inprog_n" in
    0) ok "在途切片 0 个（当前没有 status/in-progress 的 Issue）" ;;
    1) ok "在途切片 1 个（#${inprog}）—— 单写者单切片" ;;
    *) warn "有 ${inprog_n} 个 in-progress Issue（$(printf '%s' "$inprog" | tr '\n' ' ')）—— **并行是允许的**：前提是每个写者**各自独立 clone**（一个 clone = 一个写者 = 一个 Issue）；**同一 clone 内**仍然一次只做一个切片（本 clone 的锁见第 3 组；模型见 references/orchestration.md 的并发模型一节）" ;;
  esac
fi
remotes="$(git remote 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
if [ "$remotes" = "origin" ]; then
  ok "远端唯一：origin（$(git remote get-url origin 2>/dev/null || true)）"
  if git fetch -q origin 2>/dev/null; then
    lm="$(git rev-parse --short "$BASE_BRANCH" 2>/dev/null || true)"
    rm="$(git rev-parse --short "origin/${BASE_BRANCH}" 2>/dev/null || true)"
    [ -n "$lm" ] && [ "$lm" = "$rm" ] && ok "本地 ${BASE_BRANCH} 与 origin/${BASE_BRANCH} 一致（${lm}）" \
      || warn "本地 ${BASE_BRANCH}=${lm:-无} 与 origin/${BASE_BRANCH}=${rm:-无} 不一致 —— 推送前先同步"
  else
    warn "无法 fetch origin（网络或凭据问题）"
  fi
else
  bad "远端不是唯一的 origin（当前：${remotes:-无}）"
fi

info "5/10 三身份凭据（作者 / 评审 / 合并）"
# ① 作者凭据 = **本身份**凭据 → 允许读取内容（用它做本身份动作）
dev_login="$(login_via_pat "$DEVELOPER_PAT_FILE")"
if [ ! -s "$DEVELOPER_PAT_FILE" ]; then
  bad "作者凭据缺失或为空：${DEVELOPER_PAT_FILE}（见 references/identity.md）"
else
  mode="$(file_mode "$DEVELOPER_PAT_FILE")"
  [ "$mode" = "600" ] && ok "作者凭据权限 600" || bad "作者凭据权限为 ${mode}，应为 600：chmod 600 ${DEVELOPER_PAT_FILE}"
  if git ls-files --error-unmatch "$DEVELOPER_PAT_FILE" >/dev/null 2>&1; then
    bad "作者凭据**已被 git 跟踪** —— 立即 git rm --cached 并轮换该 token"
  else
    ok "作者凭据未进入版本库"
  fi
fi
[ -n "$dev_login" ] && ok "作者身份：${dev_login}" || bad "作者凭据无法认证（已过期/被撤销/不是 classic PAT）"

# ② 评审凭据：**不读取内容**（SKILL.md §5：作者不得读取其他身份的凭据）——
#    这里只做内容无关的判据；评审身份/权限由 W6 `review.sh` 用凭据自身判定。
rev_abs="$(physical "$REVIEWER_PAT_FILE")"
rev_dev_abs="$(physical "$DEVELOPER_PAT_FILE")"
if pat_in_workspace "$REVIEWER_PAT_FILE"; then
  bad "评审凭据落在**工作区内**：${rev_abs}（仓库根 ${REPO_ROOT}）—— 评审凭据必须落在工作区之外"
  printf '       搬移（由 PM / dispatcher 在**工作区外**执行）：\n' >&2
  printf '         mkdir -p "${HOME}/.config/pm4gh" && chmod 700 "${HOME}/.config/pm4gh"\n' >&2
  printf '         mv "%s" "${HOME}/.config/pm4gh/reviewer.pat"\n' "$rev_abs" >&2
  printf '         chmod 600 "${HOME}/.config/pm4gh/reviewer.pat"\n' >&2
  printf '       默认路径即此（scripts/review.sh 也拒绝工作区内的路径）；凭据缺失只报警告（见下一项）\n' >&2
else
  ok "评审凭据在工作区之外：${rev_abs}"
  if [ ! -s "$REVIEWER_PAT_FILE" ]; then
    warn "评审凭据缺失或不可读：${rev_abs} —— 不影响作者循环（W0..W5/W7/W8），但 W6 评审不可用"
    printf '       开通（由 PM / dispatcher 执行）：\n' >&2
    printf '         mkdir -p "${HOME}/.config/pm4gh" && chmod 700 "${HOME}/.config/pm4gh"\n' >&2
    printf '         # 在 GitHub 生成 classic PAT（scope: repo）后写入该路径：%s\n' "$rev_abs" >&2
    printf '         chmod 600 "${HOME}/.config/pm4gh/reviewer.pat"\n' >&2
  else
    mode="$(file_mode "$REVIEWER_PAT_FILE")"
    [ "$mode" = "600" ] && ok "评审凭据权限 600" || bad "评审凭据权限为 ${mode}，应为 600：chmod 600 ${REVIEWER_PAT_FILE}"
    if git ls-files --error-unmatch "$REVIEWER_PAT_FILE" >/dev/null 2>&1; then
      bad "评审凭据**已被 git 跟踪** —— 立即 git rm --cached 并轮换该 token"
    else
      ok "评审凭据未进入版本库"
    fi
    if [ "$rev_abs" = "$rev_dev_abs" ]; then
      bad "作者与评审凭据指向**同一个文件**：${rev_abs} —— 三身份分离不成立"
    else
      ok "作者与评审凭据是两个不同文件"
    fi
  fi
fi

# ③ 工作区内不得存在**任何**凭据文件：一旦有人把
#    凭据拷回来，隔离会被**静默**破坏 —— 这里让它可见（判据是文件系统事实，与文档怎么写无关）。
stray_pat="$(find . -path ./.git -prune -o -type f -name '*.pat' -print 2>/dev/null | sed -E 's#^\./##' | sort || true)"
if [ -n "$stray_pat" ]; then
  bad "工作区内存在凭据文件（可能被 git add 误提交）：$(printf '%s' "$stray_pat" | tr '\n' ' ')"
  printf '       搬移（由 PM / dispatcher 在**工作区外**执行）：\n' >&2
  printf '         mkdir -p "$HOME/.config/pm4gh" && chmod 700 "$HOME/.config/pm4gh"\n' >&2
  printf '         mv <上面列出的每个文件> "$HOME/.config/pm4gh/" && chmod 600 "$HOME/.config/pm4gh/"*.pat\n' >&2
else
  ok "工作区内没有任何凭据文件（*.pat）"
fi

# ④ 合并身份 = 本机 gh 登录态（不需要凭据文件）
if [ -n "$main_login" ] && [ -n "$dev_login" ] && [ "$main_login" != "$dev_login" ]; then
  ok "身份分离：合并 ${main_login} ≠ 作者 ${dev_login}"
elif [ -n "$main_login" ] && [ "$main_login" = "$dev_login" ]; then
  bad "身份分离失败：作者身份 = gh 登录身份（${main_login}）—— 检查 ${DEVELOPER_PAT_FILE} 是否放错"
fi
printf '  评审身份 ≠ 作者身份：由 W6 `review.sh` 用**评审凭据自身**判定（作者路径不读它）\n'

info "6/10 凭据 scope 与最小权限（只对作者凭据 —— 本身份）"
dev_scopes="$(scopes_via_pat "$DEVELOPER_PAT_FILE" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
if [ -z "$dev_scopes" ]; then
  bad "作者凭据读不到 OAuth scope 头 —— 无法证明 scope 合规（需要 repo + workflow）"
else
  case " ${dev_scopes} " in *" repo "*) ok "作者 scope 含 repo（实测：${dev_scopes}）" ;; *) bad "作者 scope 不含 repo（实测：${dev_scopes}）" ;; esac
  case " ${dev_scopes} " in
    *" workflow "*) ok "作者 scope 含 workflow（可推送 .github/workflows/**）" ;;
    *) bad "作者 scope 缺 workflow —— 推送 .github/workflows/** 会被服务端整体拒绝（实测：${dev_scopes}）" ;;
  esac
fi
printf '  评审凭据的认证与写权限由 W6 `review.sh` 自检（认证失败 → 报错退出；无写权限 → 其评审不计入门禁）\n'
if [ -n "$REPO" ] && [ -n "$dev_login" ]; then
  perms="$(GH_TOKEN="$(cat "$DEVELOPER_PAT_FILE")" gh api "repos/${REPO}" --jq '"\(.permissions.push)/\(.permissions.admin)"' 2>/dev/null || true)"
  case "$perms" in
    true/false) ok "作者身份 ${dev_login}：push 有、admin 无（符合最小权限）" ;;
    "")        bad "读不到作者身份对本仓库的权限（404？邀请未接受？）" ;;
    *)         warn "作者身份权限异常：push/admin=${perms}" ;;
  esac
fi

info "7/10 工作流 job 名 == 必需检查 context（逐字）"
wf_actual="$(grep -hE '^[[:space:]]+name: (ci|policy)/' .github/workflows/*.yml 2>/dev/null \
  | sed -E 's/^[[:space:]]*name:[[:space:]]*//' | sort -u || true)"
expected_sorted="$(printf '%s\n' $REQUIRED_EXPECTED | sort -u)"
if [ "$wf_actual" = "$expected_sorted" ]; then
  ok "工作流产出的检查名与 5 个必需 context 精确一致"
else
  bad "工作流 job 名与必需的 5 个 context 不一致（改名 = 所有 PR 永久 pending）。不要自行修改，报告 dispatcher。"
  warn "  期望：$(printf '%s' "$expected_sorted" | tr '\n' ' ')"
  warn "  实际：$(printf '%s' "$wf_actual" | tr '\n' ' ')"
fi

info "8/10 线上规则集 vs 仓库内定义（整份 diff，全量键）+ CODEOWNERS 完整性（防永久锁死）"
if [ -z "$REPO" ]; then
  bad "仓库 slug 未知，跳过线上规则集比对与 CODEOWNERS 完整性断言"
else
  rid="$(gh api "repos/${REPO}/rulesets" --jq '.[]|select(.name=="main-protection")|.id' 2>/dev/null | head -1 || true)"
  if [ -z "$rid" ]; then
    bad "线上没有名为 main-protection 的规则集 —— 门禁未生效（属 dispatcher 权限，请报告）"
  else
    ok "线上规则集 id=${rid}"
    live_json="$(gh api "repos/${REPO}/rulesets/${rid}" 2>/dev/null || true)"
    if [ -z "$live_json" ]; then
      bad "读不到线上规则集正文（权限？）—— 无法证明与仓库内定义一致，报告 dispatcher"
    else
      # 唯一判据：同一个 jq 程序分别作用在线上与文件上，比较规范形（见文件头 RULESET_CANON_JQ）
      live_canon="$(printf '%s' "$live_json" | jq -S "$RULESET_CANON_JQ" 2>/dev/null || true)"
      file_canon="$(jq -S "$RULESET_CANON_JQ" "$RULESET_FILE" 2>/dev/null || true)"
      if [ -z "$live_canon" ] || [ -z "$file_canon" ]; then
        bad "规则集规范化失败（jq 判据报错）—— 不要自行修改，报告 dispatcher"
      elif [ "$live_canon" = "$file_canon" ]; then
        ok "整份 ruleset 一致（全量键；判据 RULESET_CANON_JQ）"
      else
        bad "整份 ruleset 不一致：线上与 ${RULESET_FILE} 有键差异（缺键 / 多键 / 值不同）"
        warn "  下方 diff：'<' = 线上，'>' = 仓库内定义。改法只能是改文件（改线上属 dispatcher 权限）"
        diff <(printf '%s\n' "$live_canon") <(printf '%s\n' "$file_canon") >&2 || true
      fi
    fi
  fi

  # ── CODEOWNERS 完整性（P3：本次回归里唯一**不可逆**的缺陷）───────────────────
  # 死锁机理：require_code_owner_review=true 时，GitHub 要求改动由**该路径的 CODEOWNERS owner** 批准；
  #   而 CODEOWNERS **取自目标分支**（在 PR 里改它无法为这个 PR 解锁）+ 平台禁止自我批准。
  #   故以下任一成立 = 这些路径**永久无法合并**：
  #     ① 任一 owner 不是本仓库协作者（或没有 push）→ 没人能满足 owner 条件；
  #     ② 评审身份不是 `*` 规则的 owner → 评审的批准不算 code owner 批准；
  #     ③ 合并身份（dispatcher）不是协作者 → 没有合并入口。
  # 判据只**读**线上（collaborators / rulesets），不改任何线上配置；`require_code_owner_review`
  # 的取值**只认线上实测值**（仓库内 JSON 是声明，不是真值）：开关未开启时 ② 降级为提示，不误报。
  printf '\n  ── CODEOWNERS 完整性（防 require_code_owner_review 永久锁死）\n'
  CO_FILE=".github/CODEOWNERS"
  # 评审身份取自 references/identity.md 的三身份表：**不读评审凭据内容**（SKILL.md §5），
  # 那份表是无凭据条件下唯一能证明「W6 用的是哪个身份」的载体；解析不出 = 无法证明无死锁 → [FAIL]。
  co_reviewer="$(grep -E '^\|[[:space:]]*评审[[:space:]]*\|' references/identity.md 2>/dev/null \
    | head -1 | grep -oE '@[A-Za-z0-9-]+' | head -1 | sed -e 's/^@//' | tr '[:upper:]' '[:lower:]' || true)"
  co_collab="$(gh api "repos/${REPO}/collaborators?affiliation=all&per_page=100" --paginate \
    --jq '.[] | "\(.login | ascii_downcase) \(.permissions.push)"' 2>/dev/null || true)"
  if [ ! -f "$CO_FILE" ]; then
    bad "缺少 ${CO_FILE} —— require_code_owner_review 下所有 PR 永久无法合并（CODEOWNERS 取自目标分支）；恢复该文件后重跑"
  elif [ -z "$co_collab" ]; then
    bad "读不到协作者清单（repos/${REPO}/collaborators）—— 无法证明 owner 有 push；用对仓库有 push 权限的凭据重跑（合并身份 gh 登录态即可）"
  else
    co_owners="$(awk '!/^[[:space:]]*#/ && NF > 1 { for (i = 2; i <= NF; i++) if ($i ~ /^@/) { o = $i; sub(/^@/, "", o); print o } }' "$CO_FILE" \
      | tr '[:upper:]' '[:lower:]' | sort -u)"
    co_star="$(awk '$1 == "*" { for (i = 2; i <= NF; i++) if ($i ~ /^@/) { o = $i; sub(/^@/, "", o); print o } }' "$CO_FILE" \
      | tr '[:upper:]' '[:lower:]' | sort -u)"
    if [ -z "$co_owners" ]; then
      bad "${CO_FILE} 里解析不出任何 @owner（规则行形如 \`<pattern> @user\`）—— 判据无法成立，修复后重跑"
    else
      # ① 每个 owner 必须是协作者且有 push（团队 owner 用团队-仓库权限判据）
      co_bad=""
      for o in $co_owners; do
        case "$o" in
          */*)
            tp="$(gh api "orgs/${o%%/*}/teams/${o##*/}/repos/${REPO}" --jq '.permissions.push' 2>/dev/null || true)"
            [ "$tp" = "true" ] || co_bad="${co_bad} ${o}（团队不可读或无 push）"
            ;;
          *)
            grep -qxF "${o} true" <<<"$co_collab" || co_bad="${co_bad} ${o}"
            ;;
        esac
      done
      if [ -n "$co_bad" ]; then
        bad "CODEOWNERS 的 owner 不是协作者（或没有 push）：${co_bad}"
        printf '       后果：require_code_owner_review=true 时这些路径**永久无法合并**（PR 内改 CODEOWNERS 无效：它取自目标分支）\n' >&2
        printf '       修法：① 作者改 %s 的 owner（换成有 push 的协作者）；② dispatcher：gh api -X PUT repos/%s/collaborators/<login> -f permission=push\n' "$CO_FILE" "$REPO" >&2
      else
        ok "CODEOWNERS 的 owner 全部是协作者且有 push（$(printf '%s' "$co_owners" | tr '\n' ' ')）"
      fi

      # ② 评审身份必须是 `*` 规则的 owner（开关从**线上实测值**读；未开启时降级为提示）
      co_switch=""
      if [ -n "${rid:-}" ]; then
        co_switch="$(gh api "repos/${REPO}/rulesets/${rid}" \
          --jq '[.rules[]|select(.type=="pull_request")|.parameters.require_code_owner_review][0]' 2>/dev/null || true)"
      fi
      co_dev="$(printf '%s' "${dev_login:-}" | tr '[:upper:]' '[:lower:]')"
      if [ -z "$co_reviewer" ]; then
        bad "无法从 references/identity.md 的三身份表解析出评审身份 —— 无法证明评审是 \`*\` 的 owner（fail-closed）；修好该表后重跑"
      elif [ -z "$co_star" ]; then
        bad "${CO_FILE} 里没有 \`*\` 规则（或该规则没有 @owner）—— require_code_owner_review 下没有路径 owner，PR 永久无法合并"
      elif [ -z "$co_switch" ]; then
        bad "读不到线上 require_code_owner_review 的实测值（ruleset ${rid:-未知}）—— 无法判定评审身份是否必须是 \`*\` 的 owner；报告 dispatcher"
      elif [ "$co_switch" = "true" ] && ! grep -qxF "$co_reviewer" <<<"$co_star"; then
        bad "评审身份 ${co_reviewer} 不是 \`*\` 规则的 owner，而线上 require_code_owner_review=true —— 评审的批准不算 code owner 批准，PR **永久无法合并**"
        printf '       修法（作者）：在 %s 的 `*` 规则里加上 @%s（当前 owner：%s）\n' "$CO_FILE" "$co_reviewer" "$(printf '%s' "$co_star" | tr '\n' ' ')" >&2
        printf '       注意：本轮 PR 内改 CODEOWNERS **不能**解锁本 PR —— 它取自目标分支\n' >&2
      elif [ "$co_switch" = "true" ]; then
        ok "评审身份 ${co_reviewer} 是 \`*\` 规则的 owner（require_code_owner_review=true，线上实测 id=${rid}）"
      else
        ok "线上 require_code_owner_review=${co_switch}（未开启）→ 评审身份 ${co_reviewer} 是否 \`*\` 的 owner 仅作提示，不阻断：$(grep -qxF "$co_reviewer" <<<"$co_star" && printf '是 owner' || printf '不是 owner')"
      fi
      # 评审 == 作者时，即便评审是 owner 也必然锁死（平台禁止自我批准）—— 第 ② 条须同时排除该退化
      if [ -n "$co_reviewer" ] && [ -n "$co_dev" ] && [ "$co_reviewer" = "$co_dev" ]; then
        bad "评审身份 ${co_reviewer} == 作者身份 —— 平台禁止自我批准，require_code_owner_review 下必然永久锁死"
      fi

      # ③ 合并身份（dispatcher = 本机 gh 登录态）必须是协作者且有 push（合并本身就需要 push）
      if [ -z "${main_login:-}" ]; then
        bad "读不到 gh 登录身份（合并身份）—— 无法证明合并入口可用"
      elif grep -qxF "$(printf '%s' "$main_login" | tr '[:upper:]' '[:lower:]') true" <<<"$co_collab"; then
        ok "合并身份 ${main_login} 是协作者且有 push"
      else
        bad "合并身份 ${main_login} 不是协作者（或没有 push）—— 无人能合并，所有 PR 永久卡住"
        printf '       修法（dispatcher）：gh api -X PUT repos/%s/collaborators/%s -f permission=push\n' "$REPO" "$main_login" >&2
      fi
    fi
  fi

  # ── .github 内链接与当前 slug 一致性（P6：把「复制到别处后忘改」从**静默**变成预检报错）──
  # 机理：`.github/ISSUE_TEMPLATE/config.yml` 的 contact link 会**写死源仓库 URL** —— 复制到
  #   另一个仓库后，它照样把用户导向**源仓库**，且没有任何东西会报错。这里让它可见。
  # 判据：`.github/` 内出现的 `github.com/<owner>/<repo>` 形态链接，其 `<owner>/<repo>` 必须与
  #   当前仓库 slug（`gh repo view`，大小写不敏感）**逐字一致**；不一致 → `[FAIL]` 并列出替换点。
  #   本仓库自身必须全绿；被复制到别处则应报错 —— 这正是它要发现的问题。
  # 取舍：指向**第三方**仓库的 `github.com/...` 链接同样会被判为不一致（判据不猜意图）；若确需
  #   引用第三方仓库，写成不含 `github.com/` 的 `owner/repo` 文本，或报告 dispatcher 说明。
  # 采用者的替换点清单见 references/portability.md。
  printf '\n  ── .github 内链接与当前 slug 一致性（P6：判据 = gh repo view 得到的 slug）\n'
  gh_links="$(grep -rnoIE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' .github/ 2>/dev/null || true)"
  if [ -z "$gh_links" ]; then
    ok ".github/ 内没有 github.com/<owner>/<repo> 形态链接（无需替换）"
  else
    link_total=0 link_bad=""
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      link_total=$((link_total + 1))
      ln_file="${hit%%:*}"; ln_rest="${hit#*:}"; ln_no="${ln_rest%%:*}"
      ln_slug="${hit##*github.com/}"; ln_slug="${ln_slug%.git}"
      if [ "$(printf '%s' "$ln_slug" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
        printf -v link_line '%s:%s 指向 %s\n' "$ln_file" "$ln_no" "$ln_slug"
        link_bad="${link_bad}${link_line}"
      fi
    done <<<"$gh_links"
    if [ -n "$link_bad" ]; then
      bad ".github/ 内的链接指向的不是当前仓库 ${REPO}（复制后忘改 = 静默把用户导向别的仓库）："
      printf '%s' "$link_bad" >&2
      printf '       修法：把上面每处换成 https://github.com/%s/...（逐条替换点见 references/portability.md）\n' "$REPO" >&2
    else
      ok ".github/ 内 ${link_total} 处链接与当前 slug 一致（${REPO}）"
    fi
  fi
fi

info "9/10 机器消费与 Issue 表单预置的标签存在性（status/* ×3 + type/* ×4 + 模板 labels:）"
if [ -z "$REPO" ]; then
  bad "仓库 slug 未知，跳过标签存在性断言"
else
  live_labels="$(gh label list -R "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  if [ -z "$live_labels" ]; then
    bad "读不到线上标签清单（gh label list 失败）—— 无法证明机器消费的标签存在，报告 dispatcher"
  else
    # 判据见文件头 LABEL_ASSERT（与 ci/test 逐字一致）；失败原因由判据自己打印
    assert_machine_labels "$live_labels" || fail=$((fail + 1))
  fi
fi

info "10/10 未提交任何凭据"
if git grep -nE 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' -- . >/dev/null 2>&1; then
  bad "检测到疑似凭据被提交进仓库（git grep 命中）"
else
  ok "未发现凭据"
fi

echo
if [ "$fail" -eq 0 ]; then
  ok "预检全部通过，可以开始工作"
  exit 0
fi
warn "共有 ${fail} 项未通过 —— 修好再开始（不要跳过）"
exit 1
