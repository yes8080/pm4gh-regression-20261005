#!/usr/bin/env bash
# toolkit/tests/stub-gh —— self-test 专用的 gh 假实现（绝不联网，只被 tests/self-test.sh 使用）
#
# 用途：在离线沙箱里模拟 GitHub 侧对象（标签 / 规则集 / 协作者），
#       从而可以在**不触碰任何真实仓库**的前提下验证 install.sh 的
#       「创建 / 不覆盖 / 重复执行为 no-op / 失败后仍能正确归属（D6）」等语义。
#
# 需要的环境变量（由 self-test.sh 注入）：
#   STUB_STATE   状态 JSON 文件（模拟 GitHub 侧对象）
#   STUB_LOG     调用流水（只记录，不参与断言）
#   STUB_WRITES  写操作流水（断言「零写入」用）
#   STUB_REPO / STUB_BRANCH / STUB_AUTHOR / STUB_REVIEWER
#   STUB_FAIL_LABEL_NAME   指定该标签的 create「报错但对象已创建」（模拟 D6 事故）
set -eu
: "${STUB_STATE:?stub-gh 需要 STUB_STATE}"
: "${STUB_LOG:?stub-gh 需要 STUB_LOG}"

printf '%s\n' "$*" >> "$STUB_LOG"
write_log() { if [ -n "${STUB_WRITES:-}" ]; then printf '%s\n' "$*" >> "$STUB_WRITES"; fi; }
save() { local t; t="$(mktemp)"; jq "$@" "$STUB_STATE" > "$t"; mv "$t" "$STUB_STATE"; }
arg_value() {  # $1 = 旗标名 → 输出其后的取值
  local flag="$1"; shift
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "$flag" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  repo)
    sub="${1:-}"; shift || true
    case "$sub" in
      view)
        if printf '%s' " $* " | grep -q 'nameWithOwner'; then printf '%s\n' "${STUB_REPO:-}"
        else printf '%s\n' "${STUB_BRANCH:-main}"; fi ;;
      *) echo "stub-gh: 未实现 repo $sub" >&2; exit 2 ;;
    esac ;;
  label)
    sub="${1:-}"; shift || true
    case "$sub" in
      list)
        # 与真实 gh 一致：install.sh 的 --jq 会把颜色统一小写后再比对
        jq -r '.labels[] | "\(.name)\t\(.color|ascii_downcase)\t\(.description)"' "$STUB_STATE" ;;
      create)
        name="${1:-}"; shift || true
        color="$(arg_value --color "$@" || true)"; desc="$(arg_value --description "$@" || true)"
        if jq -e --arg n "$name" '.labels[] | select(.name == $n)' "$STUB_STATE" >/dev/null 2>&1; then
          echo "HTTP 422: label already exists" >&2; exit 1
        fi
        if [ -n "${STUB_FAIL_LABEL_NAME:-}" ] && [ "$name" = "$STUB_FAIL_LABEL_NAME" ]; then
          # 「命令报错，但对象其实已创建」——失败案例库 D6 的真实形态
          write_log "label create $name (报错但已创建)"
          save --arg n "$name" --arg c "$color" --arg d "$desc" '.labels += [{name:$n,color:$c,description:$d}]'
          echo "HTTP 500: unexpected error (但对象已创建)" >&2; exit 1
        fi
        write_log "label create $name"
        save --arg n "$name" --arg c "$color" --arg d "$desc" '.labels += [{name:$n,color:$c,description:$d}]' ;;
      edit)
        name="${1:-}"; shift || true
        color="$(arg_value --color "$@" || true)"; desc="$(arg_value --description "$@" || true)"
        write_log "label edit $name"
        save --arg n "$name" --arg c "$color" --arg d "$desc" \
          '.labels = [.labels[] | if .name == $n then .color = $c | .description = $d else . end]' ;;
      *) echo "stub-gh: 未实现 label $sub" >&2; exit 2 ;;
    esac ;;
  api)
    method="GET"
    if [ "${1:-}" = "-X" ]; then method="$2"; shift 2; fi
    path="${1:-}"; shift || true
    if [ "$path" = "user" ]; then
      case "${GH_TOKEN:-}" in
        fake-token-author)   printf '%s\n' "${STUB_AUTHOR:-author-bot}" ;;
        fake-token-reviewer) printf '%s\n' "${STUB_REVIEWER:-reviewer-bot}" ;;
        *)                   printf '%s\n' "${STUB_LOGIN:-tester}" ;;
      esac
      exit 0
    fi
    case "$path" in
      *"/collaborators?per_page=100")
        jq -r '.collaborators[] | "\(.login)\t\(.push)"' "$STUB_STATE" ;;
      */collaborators/*)
        acct="${path##*/}"; write_log "collaborator put $acct"
        save --arg a "$acct" '.collaborators = ([.collaborators[] | select(.login != $a)] + [{login:$a,push:true}])' ;;
      */rulesets)
        if [ "$method" = "POST" ]; then
          f="$(arg_value --input "$@" || true)"; write_log "ruleset create"
          save --argjson body "$(cat "$f")" '.rulesets += [{id: 1, name: $body.name, body: $body}]'
        else
          jq -r '.rulesets[] | "\(.name)\t\(.id)"' "$STUB_STATE"
        fi ;;
      */rulesets/*)
        rid="${path##*/}"
        if [ "$method" = "PUT" ]; then
          f="$(arg_value --input "$@" || true)"; write_log "ruleset update $rid"
          save --argjson body "$(cat "$f")" --arg id "$rid" \
            '.rulesets = [.rulesets[] | if (.id|tostring) == $id then .body = $body | .name = $body.name else . end]'
        else
          jq -c --arg id "$rid" '.rulesets[] | select((.id|tostring) == $id) | .body' "$STUB_STATE"
        fi ;;
      *) echo "stub-gh: 未实现 api $path" >&2; exit 2 ;;
    esac ;;
  *) echo "stub-gh: 未实现命令 $cmd" >&2; exit 2 ;;
esac
