#!/usr/bin/env bash
# scripts/report.sh [--days N] [--group-by week|day] [--json] [--limit N]
#
# 度量出口（决策 D9）：Projects 的 Insights 图表随 Projects 一起移除后，用 **Issue 搜索 API**
# 产出三张口径固定的表，替代原 Insights：
#   ① 在途   —— 当前开放 Issue 按 status/* 分组（无 status/* 标签 = backlog）
#   ② 吞吐   —— 窗口内已关闭且 state_reason=completed 的 Issue 数，按周/日聚合
#   ③ 返修率 —— 窗口内曾带 src/rework 的 Issue 数 / 窗口内已关闭的 Issue 数（分母为 0 时 n/a）
#
# 口径唯一来源：docs/GOVERNANCE.md §8（逐字一致，不得各自定义）；状态唯一来源：status/* 标签（决策 D9）。
#
# 纯只读：只调用 gh 的**读**接口，不修改任何 Issue / 标签 / PR；只用主身份的 gh 登录凭据，
#         不读 .secrets/**，也不依赖 Projects / project scope。
#
# 兼容性铁律（scripts/lib.sh 顶部）：bash 3.2 语法；变量后紧跟中文必须写 ${VAR}；
#         只用 sed -E；失败必须暴露而不是静默。
#
# 用法：
#   scripts/report.sh                     # 最近 30 天，按周聚合，人类可读
#   scripts/report.sh --days 7            # 最近 7 天
#   scripts/report.sh --group-by day      # 按日聚合（默认按周）
#   scripts/report.sh --json              # 机器可读 JSON（stdout 只有 JSON）
#   scripts/report.sh --limit 500         # 放宽单次读取上限（默认 200）
#
# 退出码：0 正常；2 参数或环境错误（取值非法、jq 缺 strftime 等）

set -eu
# 身份：lib.sh 在 **source 时**（早于 use_main_identity）就用 `gh repo view` 解析 REPO，
# 环境里若残留失效的 GH_TOKEN，会在那一步直接报「无法确定仓库」。本脚本只用主身份的
# gh 登录凭据（不依赖任何 PAT），所以必须在这里、source 之前就 unset（与 use_main_identity 同一动作）。
unset GH_TOKEN || true
. "$(dirname "$0")/lib.sh"

# 说明：lib.sh 的 die 用 "$*" 拼消息，会把「退出码」这个第 2 参数一并打进消息
#      （例：die "用法错误" 2 → "[FAIL] 用法错误 2"）。为让参数/环境错误返回 2
#      且消息干净，本脚本单独定义 die_env；不修改 lib.sh（治理文件改动须单独走切片）。
die_env() { printf '[FAIL] %s\n' "$1" >&2; exit 2; }

DAYS=30
GROUP_BY=week
LIMIT=200
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --days)     DAYS="${2:?--days 需要取值}"; shift 2 ;;
    --group-by) GROUP_BY="${2:?--group-by 需要取值}"; shift 2 ;;
    --limit)    LIMIT="${2:?--limit 需要取值}"; shift 2 ;;
    --json)     JSON_OUT=1; shift ;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
    *) die_env "未知参数：${1}（用 --help 查看用法）" ;;
  esac
done

require_repo_root
use_main_identity
require_cmd gh
require_cmd jq

case "$DAYS" in *[!0-9]*) die_env "--days 必须是正整数：${DAYS}" ;; esac
[ "$DAYS" -gt 0 ] || die_env "--days 必须大于 0：${DAYS}"
case "$LIMIT" in *[!0-9]*) die_env "--limit 必须是正整数：${LIMIT}" ;; esac
[ "$LIMIT" -gt 0 ] || die_env "--limit 必须大于 0：${LIMIT}"
case "$GROUP_BY" in
  week|day) : ;;
  *) die_env "--group-by 只能是 week 或 day：${GROUP_BY}" ;;
esac

# 按周/日聚合依赖 jq 的 gmtime/strftime（jq 1.6+）；不支持就直接失败，不静默降级
jq -n '0 | gmtime | strftime("%Y-%m-%d")' >/dev/null 2>&1 \
  || die_env "当前 jq 不支持 gmtime/strftime，无法聚合（需要 jq 1.6+）"

# 窗口起始日：macOS(BSD date -v) 与 GNU(date -d) 两条路径，都不支持就失败
since_date() {
  local n="$1"
  if date -v-"${n}"d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-"${n}"d +%Y-%m-%d
  elif date -d "${n} days ago" +%Y-%m-%d >/dev/null 2>&1; then
    date -d "${n} days ago" +%Y-%m-%d
  else
    return 1
  fi
}
SINCE="$(since_date "$DAYS")" || die_env "无法计算窗口起始日期：date 既不支持 -v 也不支持 -d"

if [ "$JSON_OUT" -eq 0 ]; then
  info "只读读取：repo=${REPO} 窗口=最近 ${DAYS} 天（since ${SINCE}）聚合=${GROUP_BY}"
fi

# ── 三个只读查询（Issue 搜索 API）─────────────────────────────
# ① 在途：开放 Issue + 其 status/* 标签
open_json="$(gh issue list -R "$REPO" --state open --limit "$LIMIT" \
  --json number,title,labels,url)"
# ② 吞吐：窗口内关闭的 Issue（state_reason 用 stateReason 字段区分 completed / not planned）
closed_json="$(gh issue list -R "$REPO" --state closed --search "closed:>=${SINCE}" --limit "$LIMIT" \
  --json number,title,closedAt,stateReason,labels,url)"
# ③ 返修：全部带 src/rework 的 Issue（↔ GOVERNANCE §8「返修率」分子：窗口内曾带该标签的 Issue）
rework_json="$(gh issue list -R "$REPO" --state all --label src/rework --limit "$LIMIT" \
  --json number,title,state,url)"

# ── 一次 jq 计算，产出唯一中间表示（文本与 JSON 两种渲染共用，杜绝口径分叉）──
report="$(jq -n \
  --arg repo "$REPO" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg since "$SINCE" \
  --arg group_by "$GROUP_BY" \
  --argjson days "$DAYS" \
  --argjson limit "$LIMIT" \
  --argjson open "$open_json" \
  --argjson closed "$closed_json" \
  --argjson rework "$rework_json" '
  def allowed_status:
    ["status/ready","status/in-progress","status/in-review","status/acceptance","status/rework"];
  def statskey:
    ([(.labels // [])[].name | select(startswith("status/"))]) as $ls
    | if ($ls | length) == 0 then "backlog"
      elif ($ls | length) > 1 then "violation"
      elif (allowed_status | index($ls[0])) then ($ls[0] | sub("^status/"; ""))
      else "violation"
      end;
  def rank(s):
    {"violation":0,"in-progress":1,"in-review":2,"acceptance":3,"rework":4,"ready":5,"backlog":6}[s] // 90;

  ($open | map({number, title, url, labels, status: statskey})) as $flow
  | ($closed | map(select(.stateReason == "COMPLETED"))) as $done
  | {
      repo: $repo,
      generated_at: $generated,
      read_only: true,
      window: {days: $days, since: $since, group_by: $group_by, limit: $limit},
      in_flight: {
        total: ($flow | length),
        truncated: (($flow | length) >= $limit),
        by_status: ($flow
          | group_by(.status)
          | map({status: .[0].status, count: length,
                 issues: (sort_by(.number) | map({number, title, url}))})
          | sort_by(rank(.status)))
      },
      throughput: {
        completed_in_window: ($done | length),
        truncated: (($done | length) >= $limit),
        buckets: ($done
          | map((.closedAt | fromdateiso8601) as $e
                | (($e / 86400) | floor) as $day
                | (if $group_by == "day" then $day
                   else ($day - (((($day + 3) % 7) + 1) - 1)) end) as $b
                | {bucket_day: $b,
                   label: (if $group_by == "day"
                           then (($b * 86400) | gmtime | strftime("%Y-%m-%d"))
                           else ((($b * 86400) | gmtime | strftime("%G-W%V"))
                                 + " (" + ((($b * 86400) | gmtime | strftime("%m-%d"))
                                 + "~" + ((($b + 6) * 86400) | gmtime | strftime("%m-%d")) + ")"))
                           end),
                   number, title, url})
          | sort_by(.bucket_day)
          | group_by(.bucket_day)
          | map({bucket: .[0].label, bucket_day: .[0].bucket_day, count: length,
                 issues: (sort_by(.number) | map({number, title, url}))}))
      },
      rework: {
        labeled_total: ($rework | length),
        labeled: ($rework | sort_by(.number) | map({number, title, state, url})),
        closed_in_window_with_label: ($done
          | map(select([(.labels // [])[].name] | index("src/rework"))) | length),
        denominator: ($done | length),
        rate: (if ($done | length) > 0
               then (($rework | length) / ($done | length))
               else null end)
      },
      status_violations: ($flow
        | map(select(.status == "violation"))
        | map({number, title, url,
               status_labels: ([(.labels // [])[].name | select(startswith("status/"))])}))
    }
')"

# ── 数据质量告警：截断与状态不变量（写 stderr，不污染 stdout 的 JSON）──
trunc="$(printf '%s' "$report" | jq -r '[.in_flight.truncated, .throughput.truncated] | any')"
if [ "$trunc" = "true" ]; then
  warn "读取结果达到 --limit ${LIMIT}，可能被截断 —— 用 --limit 放宽后重跑"
fi
viol="$(printf '%s' "$report" | jq -r '.status_violations | length')"
if [ "$viol" -gt 0 ]; then
  warn "检测到 ${viol} 个 Issue 的 status/* 标签违反不变量（合法值唯一且互斥）—— 用 scripts/status.sh 修正："
  printf '%s' "$report" \
    | jq -r '.status_violations[] | "  #\(.number)  [\(.status_labels | join(","))]  \(.title)"' >&2
fi

# ── 渲染 ────────────────────────────────────────────────────
if [ "$JSON_OUT" -eq 1 ]; then
  printf '%s\n' "$report"
  exit 0
fi

printf '%s' "$report" | jq -r '
  "pm4gh 度量报告",
  "仓库：\(.repo)   窗口：最近 \(.window.days) 天（since \(.window.since)）   聚合：\(.window.group_by)",
  "生成时间：\(.generated_at)   （只读；口径见 docs/GOVERNANCE.md §8）",
  "",
  "① 在途（开放 Issue 按 status/* 分组；backlog = 无 status/* 标签）",
  (if (.in_flight.by_status | length) == 0 then "  （无开放 Issue）" else empty end),
  (.in_flight.by_status[] |
     ((if .status == "backlog" then "backlog（无 status/* 标签）"
       elif .status == "violation" then "违反不变量（status/* 不唯一或取值非法）"
       else "status/\(.status)" end)
      + "   " + (.count | tostring) + " 个"),
     (.issues[] | "      #\(.number)  \(.title)")),
  "  合计 \(.in_flight.total) 个",
  "",
  "② 吞吐（窗口内已关闭且 state_reason=completed；按\(if .window.group_by == "day" then "日" else "周" end)聚合）",
  (if (.throughput.buckets | length) == 0 then "  （窗口内无已完成 Issue）" else empty end),
  (.throughput.buckets[] |
     "  \(.bucket)   \(.count) 个   " + (.issues | map("#\(.number)") | join(" "))),
  "  合计 \(.throughput.completed_in_window) 个",
  "",
  "③ 返修率（分子＝窗口内曾带 src/rework 的 Issue 数；分母＝窗口内已关闭的 Issue 数；分母为 0 时 n/a）",
  "  带 src/rework 的 Issue：\(.rework.labeled_total) 个（其中窗口内已关闭：\(.rework.closed_in_window_with_label) 个）",
  "  窗口内已关闭：\(.rework.denominator) 个",
  "  返修率 = \(.rework.labeled_total) / \(.rework.denominator) = "
    + (if .rework.rate == null then "n/a（分母为 0）"
       else ((.rework.rate * 1000 | round) / 10 | tostring) + "%" end),
  (if (.rework.labeled | length) > 0
   then (.rework.labeled[] | "      #\(.number)  [\(.state)]  \(.title)")
   else empty end)
'
