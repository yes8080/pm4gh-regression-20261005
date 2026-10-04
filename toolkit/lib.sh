#!/usr/bin/env bash
# toolkit/lib.sh —— 治理套件 install.sh / eject.sh 的公共 helper（被 source，不单独执行）
#
# 为什么要抽出来（E2-S2 引入）：
#   `install.sh`（S1）与 `eject.sh`（S2）必须用**同一份**归属/漂移判定逻辑：
#   install 判定 owned=true 的依据、以及"对象是否漂移"的判据，如果各写一份，
#   就会出现"install 认为 owned、eject 认为不是"这类**静默不一致** ——
#   而本套件的唯一归属依据本来就是 manifest.json，判定逻辑自然也必须唯一。
#
# 兼容性铁律（与 scripts/lib.sh 相同，本项目实测踩坑）：
#   1. 只用 bash 3.2 语法：禁止 mapfile / readarray / declare -A / ${var,,}
#   2. 变量后紧跟中文等多字节字符时必须写 ${VAR}，否则 bash 3.2 会把字节序列并入变量名
#
# 依赖调用方在**调用时**已定义下列全局量（lib.sh 只在函数体内引用它们）：
#   KIT_DIR / ROOT / REPO / TMP_DIR / MANIFEST / OWNER / DEFAULT_BRANCH
#   AUTHOR_ACCOUNT / REVIEWER_ACCOUNT
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
    -e "s|@@AUTHOR_ACCOUNT@@|${AUTHOR_ACCOUNT}|g" \
    -e "s|@@REVIEWER_ACCOUNT@@|${REVIEWER_ACCOUNT}|g" "$1"
}
render_str() { printf '%s' "$1" | render_stream /dev/stdin; }
render_to() {
  if [ "$3" = "true" ]; then render_stream "$1" > "$2"; else cp "$1" "$2"; fi
}
jget() { printf '%s' "$1" | jq -r "$2"; }

# ── 归属记账（manifest.json 的 ledger 段）───────────────────────
# owned 的判定与 install.sh 完全一致：owned=true **或** 留有 create 意图（D6：命令报错但对象已创建）
ledger_owned() {
  [ "$(jq -r --arg id "$1" '((.ledger[$id] // {}).owned // false) or (((.ledger[$id] // {}).intent // "") == "create")' "$MANIFEST")" = "true" ]
}
# 写前落账：先登记 create 意图，再执行；即使命令报错/进程中断，下次运行仍能正确归属（D6）
ledger_mark_intent() {
  local tmp
  tmp="$(mktemp "${TMP_DIR}/mf.XXXXXX")"
  jq --arg id "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.ledger[$id] = {phase:"planned", intent:"create", observed:"unknown", owned:false, pre_existing:false, recorded_at:$ts}' \
     "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
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

# ── CODEOWNERS 归一化（忽略多余空白与注释/空行）──────────────────
normalize_co() { sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' "$1" | grep -vE '^[[:space:]]*(#|$)' || true; }
