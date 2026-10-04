#!/usr/bin/env bash
# toolkit/lib.sh —— 治理套件 install.sh / eject.sh 的公共 helper（被 source，不单独执行）
#
# 为什么要抽出来（E2-S2 引入）：
#   `install.sh`（S1）与 `eject.sh`（S2）必须用**同一份**归属/漂移判定逻辑：
#   install 判定 owned=true 的依据、以及"对象是否漂移"的判据，如果各写一份，
#   就会出现"install 认为 owned、eject 认为不是"这类**静默不一致** ——
#   而本套件的归属判据本来就是唯一的，判定逻辑自然也必须唯一。
#
# 声明与状态分离（Issue #69 / S-A，设计 #68 §2.1）：
#   KIT_YAML = **出厂声明**（`<kit-dir>/kit.yaml`，进版本库、运行时只读、可审计可 diff）
#   KIT_JSON = 运行时由 kit.yaml **派生**的 JSON（在临时区，进不了版本库）——
#              其余判据（install/eject/不变量检查）全部建立在 jq 之上，故只在这里转换一次
#   LEDGER   = **安装器事务账**（`<root>/.git/governance-ledger.json`，**不进版本库**）
#   `kit_purity_check` 在每次运行收尾时断言 kit.yaml 逐字节未变（Bug #60 的护栏）。
#
# 兼容性铁律（与 scripts/lib.sh 相同，本项目实测踩坑）：
#   1. 只用 bash 3.2 语法：禁止 mapfile / readarray / declare -A / ${var,,}
#   2. 变量后紧跟中文等多字节字符时必须写 ${VAR}，否则 bash 3.2 会把字节序列并入变量名
#
# 依赖调用方在**调用时**已定义下列全局量（lib.sh 只在函数体内引用它们）：
#   KIT_DIR / KIT_YAML / ROOT / REPO / TMP_DIR / KIT_JSON / LEDGER / OWNER / DEFAULT_BRANCH
#   KIT_ROOT / AUTHOR_ACCOUNT / REVIEWER_ACCOUNT
# lib.sh 不设置 `set -eu`（由调用方设置），不注册 trap，不定义 `die`（两个脚本的默认退出码不同）。

log()  { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

# ── 身份账号（只读凭据文件内容做身份确认；从不打印、从不落盘）──────────
identity_from_pat() {
  local f="$1"
  [ -s "$f" ] || return 1
  ( GH_TOKEN="$(cat "$f")"; export GH_TOKEN; gh api user --jq .login 2>/dev/null ) || return 1
}

# ── 占位符替换（@@NAME@@）─────────────────────────────────────
# 注意：渲染必须走 sed 流，不能用 "$(cat ...)" —— 命令替换会吃掉文件末尾换行，
# 会让"渲染结果"与仓库内文件永久差一个换行（本地实测踩到）。
# 两类账号占位符：@@OWNER@@/@@REVIEWER_ACCOUNT@@ = 裸登录名；@@OWNER_MENTION@@/@@REVIEWER_MENTION@@ = @登录名
render_stream() {
  sed -E \
    -e "s|@@OWNER_MENTION@@|@${OWNER}|g" \
    -e "s|@@REVIEWER_MENTION@@|@${REVIEWER_ACCOUNT}|g" \
    -e "s|@@REPO@@|${REPO}|g" \
    -e "s|@@DEFAULT_BRANCH@@|${DEFAULT_BRANCH}|g" \
    -e "s|@@OWNER@@|${OWNER}|g" \
    -e "s|@@KIT_ROOT@@|${KIT_ROOT:-}|g" \
    -e "s|@@KIT_GOVERNANCE_DIR@@|${KIT_GOVERNANCE_DIR:-}|g" \
    -e "s|@@RULESET_DECL_PATH@@|${RULESET_DECL_PATH:-}|g" \
    -e "s|@@CODEOWNERS_PATH@@|${CODEOWNERS_PATH:-}|g" \
    -e "s|@@WORKFLOWS_GLOB@@|${WORKFLOWS_GLOB:-}|g" \
    -e "s|@@CODE_OWNER_IDS@@|${CODE_OWNER_IDS:-}|g" \
    -e "s|@@AUTHOR_ACCOUNT@@|${AUTHOR_ACCOUNT}|g" \
    -e "s|@@REVIEWER_ACCOUNT@@|${REVIEWER_ACCOUNT}|g" "$1"
}
render_str() { printf '%s' "$1" | render_stream /dev/stdin; }
render_to() {
  if [ "$3" = "true" ]; then render_stream "$1" > "$2"; else cp "$1" "$2"; fi
}
jget() { printf '%s' "$1" | jq -r "$2"; }
# 两个路径是否指向同一目录（install/eject 共用；用于"套件就地运行"的判定）
same_dir() { [ "$(cd "$1" 2>/dev/null && pwd)" = "$(cd "$2" 2>/dev/null && pwd)" ]; }

# ── 出厂声明：kit.yaml → JSON（运行时**只读**；派生文件不进版本库）────────
kit_load() {
  KIT_JSON="${TMP_DIR}/kit.json"
  [ -f "$KIT_YAML" ] || die "找不到出厂声明 ${KIT_YAML}（用 --kit-yaml 指定）"
  command -v python3 >/dev/null 2>&1 || die "缺少 python3 —— kit.yaml → JSON 的解析器（scripts/yaml2json.py）需要它；NFR-01 允许 bash/git/gh/jq/python3"
  if ! python3 "${KIT_DIR}/scripts/yaml2json.py" "$KIT_YAML" > "$KIT_JSON" 2>"${TMP_DIR}/kit.parse.err"; then
    cat "${TMP_DIR}/kit.parse.err" >&2
    die "出厂声明解析失败：${KIT_YAML}（解析器只支持文档化的 YAML 子集，且**不猜测**）"
  fi
  jq -e '.objects and .namespace and .ledger' "$KIT_JSON" >/dev/null 2>&1 \
    || die "出厂声明缺少必需段（objects / namespace / ledger）：${KIT_YAML}"
  KIT_YAML_HASH="$(file_hash "$KIT_YAML")"
}
# Bug #60 护栏：出厂声明是「管什么」的**配置**，运行时绝不写入 —— 收尾时逐字节断言。
kit_purity_check() {
  [ -n "${KIT_YAML_HASH:-}" ] || return 0
  [ "$(file_hash "$KIT_YAML")" = "$KIT_YAML_HASH" ] \
    || die "出厂声明在本次运行中被改写了：${KIT_YAML}
  kit.yaml 是**出厂配置**（与目标仓库无关），运行时只读；
  「实际创建了什么」必须写进 ledger（${LEDGER}）—— 这正是 Bug #60 的根因（配置与状态混放）。" 2
}

# ── 命名空间归属（设计 #68 §2.2 / PM 决策 P-5）──────────────────
# 目的：每个由套件创建的对象都能**自证归属**，不依赖 ledger → ledger 丢失也能安全卸载。
ns_files()     { jq -r '.namespace.managed_files' "$KIT_JSON"; }
ns_workflows() { jq -r '.namespace.managed_workflows' "$KIT_JSON"; }
ns_labels()    { jq -r '.namespace.ownership_labels' "$KIT_JSON"; }
ns_rulesets()  { jq -r '.namespace.managed_rulesets' "$KIT_JSON"; }
# 违反命名空间且**不在显式豁免清单**里的受管对象（TSV: class \t id \t 原因）
namespace_violations() {
  local f w l r
  f="$(ns_files)"; w="$(ns_workflows)"; l="$(ns_labels)"; r="$(ns_rulesets)"
  # 注意：下面的 select 管道里 `.` 已经是**条目对象**，因此豁免判据必须把根文档显式传进去
  # （早期写法在 def 里用 `.namespace`，在管道里就变成了"条目对象的 namespace" → 恒为 null，
  #  于是**全部**受管对象都被误报为越界 —— 这正是本项目反复强调的"判据看起来在跑其实什么都没验"）。
  jq -r --arg f "$f" --arg w "$w" --arg l "$l" --arg r "$r" '
    def file_exempt($root; $p): any($root.namespace.file_exemptions[]?; .path as $x | $p | startswith($x));
    def label_exempt($root; $n): any($root.namespace.label_exemptions[]?; .prefix as $x | $n | startswith($x));
    . as $root
    | ( .objects.files.entries[]? | (.path) as $p
        | select(($p | startswith($f)) | not)
        | select(file_exempt($root; $p) | not)
        | "files\t\(.id)\t路径 \($p) 不在 \($f)** 之内，且未列入 namespace.file_exemptions" ),
      ( .objects.workflows.entries[]? | (.path) as $p
        | select(($p | startswith($w)) | not)
        | "workflows\t\(.id)\t路径 \($p) 不是 \($w)*.yml" ),
      ( .objects.labels.entries[]? | (.name) as $n
        | select(($n | startswith($l)) | not)
        | select(label_exempt($root; $n) | not)
        | "labels\t\(.id)\t标签 \($n) 不带 \($l) 前缀，且未列入 namespace.label_exemptions" ),
      ( .objects.rulesets.entries[]? | (.name) as $n
        | select(($n | startswith($r)) | not)
        | "rulesets\t\(.id)\t规则集 \($n) 不带 \($r) 前缀" )
  ' "$KIT_JSON"
}
# 豁免必须**带理由**（不允许"来路不明的豁免"把命名空间掏空）
namespace_exemption_gaps() {
  jq -r '(.namespace.file_exemptions[]? | select((.reason // "") == "") | "file\t\(.path)\t豁免未写理由"),
         (.namespace.label_exemptions[]? | select((.reason // "") == "") | "label\t\(.prefix)\t豁免未写理由"),
         (select((.namespace.file_exemptions // null) == null) | "file_exemptions\t(缺失)"),
         (select((.namespace.label_exemptions // null) == null) | "label_exemptions\t(缺失)")' "$KIT_JSON"
}
# 供报告使用：把豁免清单打成人可读的行
namespace_exemption_report() {
  jq -r '(.namespace.file_exemptions[]? | "    文件豁免：\(.path) —— \(.reason)"),
         (.namespace.label_exemptions[]? | "    标签豁免：\(.prefix)* —— \(.reason)")' "$KIT_JSON"
}

# ── 归属记账（**版本库之外**的运行时事务记录，不是第二个状态源）──────────
# 设计依据（Bug #60，P0）：S1 把两种本质不同的东西塞进了同一个 manifest.json ——
#   ① 配置：本套件管哪些对象（与目标仓库无关，可版本控制、可分发）
#   ② 状态：本次安装**实际创建了什么**（含目标特有数据，不应版本控制）
# 后果：真用一次套件就把真实账号写进分发物，套件自带的必需检查 ci/test 必然变红
#        （`T0.1 toolkit/ 内不得出现真实账号名`），且重装/换目标产生无意义 diff。
# 修复后的职责分离（契约不变，只是拆开）：
#   kit.yaml = 出厂配置（定义「管什么」）—— 在版本库内，**运行时绝不写入**
#   LEDGER   = 运行时记账（记录「实际创建了什么」）—— 默认 <root>/.git/governance-ledger.json，
#              **在版本库之外**（设计 #68 决策 P-4；硬理由：必须活过 `git clean -fdx`）
# 默认路径与两处脚本的一致性由 self-test 断言（install/eject 必须同源）。
ledger_default() {  # $1 = ROOT
  if [ -d "${1}/.git" ]; then printf '%s\n' "${1}/.git/governance-ledger.json"
  else printf '%s\n' "${1}/.governance-ledger.json"; fi
}
ledger_init_if_missing() {
  [ -f "$LEDGER" ] && return 0
  mkdir -p "$(dirname "$LEDGER")"
  local tmp; tmp="$(mktemp "${TMP_DIR}/ledger.XXXXXX")"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg kv "$(jq -r '.kit.version' "$KIT_JSON")" \
    '{ledger_version:1, kit:"portable-governance-toolkit", kit_version:$kv, declaration:"kit.yaml",
      generated_at:$ts, repo:"", default_branch:"", updated_at:$ts, entries:{}}' > "$tmp"
  mv "$tmp" "$LEDGER"
}
# Bug #60 追加要求：--check 在记账缺失时必须**明确报错**，
# 不得静默把"本套件创建的对象"当成"装机前已存在"（那样既不报漂移、也无法卸载）。
ledger_require() {
  [ -f "$LEDGER" ] || die "归属记账不存在：${LEDGER}
  本套件**拒绝在缺少归属记账时猜测归属** —— 那会静默把「本套件创建的对象」当成
  「装机前已存在」，于是既不报漂移、也无法卸载（Bug #60）。
  · 首次安装：运行 install.sh --apply（它会创建记账）。
  · 记账被误删：**不用慌，命名空间归属仍然成立** —— 运行
        toolkit/governance ledger rebuild
    以「命名空间 + 出厂内容指纹」重新 snapshot 线上对象来重建账本（设计 #68 §2.1.1 / §2.2）。
  · 也可以从备份恢复，或用 --ledger FILE / TOOLKIT_LEDGER=... 指定路径。
  注：记账默认位于 <root>/.git/governance-ledger.json（**在版本库之外**），
      请不要把它提交进仓库 —— 那是 Bug #60 的成因。" 2
}
# owned 的判定：owned=true **或** 留有 create 意图（D6：命令报错但对象已创建）
ledger_owned() {
  if [ ! -f "$LEDGER" ]; then
    if [ "${LEDGER_LENIENT:-0}" = "1" ]; then
      if [ "${LEDGER_WARNED:-0}" != "1" ]; then
        LEDGER_WARNED=1
        warn "归属记账不存在（${LEDGER}）：无法判定归属 → 保守地按「非本套件创建」处理（不覆盖、不接管）。--dry-run 零写入，不创建记账；--check/--apply 则会直接报错。"
      fi
      return 1
    fi
    ledger_require
  fi
  [ "$(jq -r --arg id "$1" '((.entries[$id] // {}).owned // false) or (((.entries[$id] // {}).intent // "") == "create")' "$LEDGER")" = "true" ]
}
ledger_get() {  # $1 = id, $2 = 字段名
  [ -f "$LEDGER" ] || { printf 'false\n'; return 0; }
  jq -r --arg id "$1" --arg k "$2" '(.entries[$id] // {})[$k] // false' "$LEDGER"
}
# 写前落账：先登记 create 意图，再执行；即使命令报错/进程中断，下次运行仍能正确归属（D6）
ledger_mark_intent() {
  local tmp
  ledger_init_if_missing
  tmp="$(mktemp "${TMP_DIR}/ledger.XXXXXX")"
  jq --arg id "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo "$REPO" --arg br "$DEFAULT_BRANCH" \
     '.repo = $repo | .default_branch = $br | .updated_at = $ts
      | .entries[$id] = {phase:"planned", intent:"create", observed:"unknown", owned:false, pre_existing:false, recorded_at:$ts}' \
     "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
}
# 记录/清除"本套件在阶段 A 主动收窄了该规则集"（Bug #60 的顺序要求）：
# 收窄是**我们的**动作，必须在归属记账里留痕，否则 eject 会把自己的收窄误判成"漂移"而拒绝删除。
ledger_mark_narrowed() {
  local tmp; ledger_init_if_missing
  tmp="$(mktemp "${TMP_DIR}/ledger.XXXXXX")"
  jq --arg id "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.entries[$id] = ((.entries[$id] // {}) + {narrowed:true, narrowed_at:$ts}) | .updated_at = $ts' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
}
ledger_clear_narrowed() {
  [ -f "$LEDGER" ] || return 0
  local tmp; tmp="$(mktemp "${TMP_DIR}/ledger.XXXXXX")"
  jq --arg id "$1" 'if (.entries[$id] // null) != null then .entries[$id] |= del(.narrowed, .narrowed_at) else . end' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
}
ledger_total()       { [ -f "$LEDGER" ] || { printf '0\n'; return 0; }; jq -r '.entries | length' "$LEDGER"; }
ledger_owned_total() { [ -f "$LEDGER" ] || { printf '0\n'; return 0; }; jq -r '[.entries[] | select(.owned == true)] | length' "$LEDGER"; }
# 记账**绝不能被 git 跟踪**（Bug #60 护栏）：一旦入库，真实账号与"本仓库创建了什么"
# 就进了分发物，套件自带的 ci/test 必然变红。install/eject 都在启动时硬校验。
ledger_reject_if_tracked() {
  command -v git >/dev/null 2>&1 || return 0
  [ -d "${ROOT}/.git" ] || return 0
  local rel="$1"
  case "$rel" in "${ROOT}/"*) rel="${rel#${ROOT}/}" ;; esac
  case "$rel" in /*) return 0 ;; esac
  if git -C "$ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    die "归属记账被 git 跟踪了：${rel}
  记账属于**运行时状态**，必须留在版本库之外（Bug #60）。
  处理：git rm --cached '${rel}'（并确认 .gitignore 覆盖），或改用 --ledger <root>/.git/governance-ledger.json。" 2
  fi
}

# ── 文件/目录指纹（install 与 eject 同源，用于「整树已登记且未漂移」判定）──
file_hash() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else cksum "$1" | awk '{print $1 "-" $2}'; fi
}
# 目录下所有**普通文件**的相对路径（LC_ALL=C 稳定排序；不含 .git 与记账文件）
dir_rel_files() {  # $1 = 目录, $2 = 需要忽略的相对路径（通常是记账文件）
  local d="$1" skip="${2:-}"
  [ -d "$d" ] || return 0
  ( cd "$d" && find . -type d -name .git -prune -o -type f -print 2>/dev/null ) \
    | sed -E 's|^\./||' | LC_ALL=C sort | while IFS= read -r r; do
        if [ -z "$r" ]; then continue; fi
        if [ -n "$skip" ] && [ "$r" = "$skip" ]; then continue; fi
        printf '%s\n' "$r"
      done
}
# 目录内容指纹：逐文件 sha256 的聚合（用于"整树未漂移"判定；路径与内容任一变化都变）
dir_hash() {  # $1 = 目录, $2 = 可选忽略的相对路径
  local rel
  dir_rel_files "$1" "${2:-}" | while IFS= read -r rel; do
    printf '%s\t%s\n' "$rel" "$(file_hash "${1}/${rel}")"
  done | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; } | awk '{print $1}'
}

# ── 线上实况探测（每次运行都重新读，绝不信任上一次的记账）──────────
probe_labels() {
  gh label list -R "$REPO" -L 200 --json name,color,description \
    --jq '.[] | "\(.name)\t\(.color|ascii_downcase)\t\(.description)"' > "${TMP_DIR}/live_labels.tsv" 2>/dev/null || : > "${TMP_DIR}/live_labels.tsv"
}
probe_collaborators() {
  gh api "repos/${REPO}/collaborators?per_page=100" \
    --jq '.[] | "\(.login)\t\(.permissions.push)"' > "${TMP_DIR}/live_collab.tsv" 2>/dev/null || : > "${TMP_DIR}/live_collab.tsv"
}
probe_ruleset_ids() {
  gh api "repos/${REPO}/rulesets" --jq '.[] | "\(.name)\t\(.id)"' > "${TMP_DIR}/live_rulesets.tsv" 2>/dev/null || : > "${TMP_DIR}/live_rulesets.tsv"
}
ruleset_id_by_name() { awk -F '\t' -v n="$1" '$1 == n { print $2; exit }' "${TMP_DIR}/live_rulesets.tsv"; }
ruleset_fetch() { gh api "repos/${REPO}/rulesets/$1" 2>/dev/null; }
# 写入线上前先剥掉仅供本地阅读的 _comment* 字段（GitHub API 不接受未知字段）
ruleset_body() {  # $1 = payload 文件 → 输出可提交的 JSON
  jq 'with_entries(select(.key | startswith("_") | not))' "$1"
}

# 规则集语义比对：期望的参数必须与线上一致；线上多出的字段/规则只报告（平台默认值会多出字段）
ruleset_diff() {
  jq -r -n --slurpfile W "$1" --slurpfile L "$2" '
    ($W[0]) as $w | ($L[0]) as $l |
    ( if $w.name != $l.name then "name|\($w.name)|\($l.name)" else empty end ),
    ( if $w.target != $l.target then "target|\($w.target)|\($l.target)" else empty end ),
    ( if $w.enforcement != $l.enforcement then "enforcement|\($w.enforcement)|\($l.enforcement)" else empty end ),
    ( if (($w.conditions.ref_name.include // [])|sort|join(",")) != (($l.conditions.ref_name.include // [])|sort|join(","))
      then "ref_include|\(($w.conditions.ref_name.include // [])|sort|join(","))|\(($l.conditions.ref_name.include // [])|sort|join(","))" else empty end ),
    ( if (($w.bypass_actors // [])|length) != (($l.bypass_actors // [])|length)
      then "bypass|\(($w.bypass_actors // [])|length)|\(($l.bypass_actors // [])|length)" else empty end ),
    ( $w.rules[] | .type as $t |
        ( if ([ $l.rules[] | select(.type == $t) ] | length) == 0 then "rule_missing|\($t)|" else empty end ) ),
    ( $w.rules[] | select(.type != "required_status_checks") | .type as $t | (.parameters // {}) | to_entries[] |
        .key as $k | .value as $v |
        ( [ $l.rules[] | select(.type == $t) ] | .[0].parameters[$k] ) as $lv |
        ( if ($lv != $v) then "param|\($t).\($k)|期望 \($v|tojson) / 实际 \($lv|tojson)" else empty end ) ),
    ( $l.rules[] | select(.type != "required_status_checks") | .type as $t | (.parameters // {}) | to_entries[] |
        .key as $k |
        ( if ((([ $w.rules[] | select(.type == $t) ] | .[0].parameters) // {}) | has($k)) then empty
          else "extra_param|\($t).\($k)|线上多出（平台默认值，仅报告）" end ) ),
    ( $w.rules[] | select(.type == "required_status_checks") |
        ( [.parameters.required_status_checks[].context] | sort | join(",") ) as $wc |
        ( [ $l.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context ] | sort | join(",") ) as $lc |
        ( if $wc != $lc then "contexts|\($wc)|\($lc)" else empty end ) ),
    ( $l.rules[] | .type as $t |
        ( if ([ $w.rules[] | select(.type == $t) ] | length) == 0 then "extra_rule|\($t)|线上多出（非本套件声明，仅报告）" else empty end ) )
  '
}

# ── 标签 payload 解析 ─────────────────────────────────────────
parse_label_source() {  # $1 = labels.yml → TSV(name color description)
  awk '
    function val(line,   p, s) {
      p = index(line, ":"); if (p == 0) return ""
      s = substr(line, p + 1); gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
      gsub(/^"/, "", s); gsub(/"$/, "", s); return s
    }
    /^[ \t]*-[ \t]*name:/ { if (n != "") print n "\t" c "\t" d; n = val($0); c = ""; d = ""; next }
    /^[ \t]*color:/       { c = val($0); next }
    /^[ \t]*description:/ { d = val($0); next }
    END                   { if (n != "") print n "\t" c "\t" d }
  ' "$1"
}
label_want() { awk -F '\t' -v n="$1" '$1 == n { print tolower($2) "\t" $3; exit }' "${TMP_DIR}/want_labels.tsv"; }

