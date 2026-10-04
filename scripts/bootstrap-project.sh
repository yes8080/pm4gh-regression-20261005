#!/usr/bin/env bash
# scripts/bootstrap-project.sh [--dry-run] [--check]
#
# 把 Projects 的**字段、视图、条目**变成可重建的代码资产（而不是手工点出来的）。
#
# 为什么用纯 GraphQL 而不是 `gh project`：
#   ① `gh project list --owner @me` 需要额外的 `read:org` + `read:discussion` scope，
#      而本项目刻意把凭据面收窄到 `project` + `repo`（实测报 missing required scopes）
#   ② `gh project field-create` **不支持 iteration 字段**
#   ③ `gh project create` 在本机会报 "unknown owner type"
#   → GraphQL 通路完整可用，且覆盖 CLI 的全部缺口
#
# **能力边界（官方，务必知道）**：
#   · 视图**过滤器**只能"先 create 再 update"（createProjectV2View 没有 filter 参数）
#   · 视图**分组（Group by）无法通过 API 设置** → 必须 UI 手工
#   · **内置自动化（加入→Todo / 关闭→Done / 合并→Done / auto-add / auto-archive）无法通过 API 开启**
#     —— GraphQL 只有 deleteProjectV2Workflow，没有任何 create/enable 变更
#   → 本脚本 --check 会**检测并提示**这些必须人工完成的项（清单见 docs/PLAYBOOK.md §9）
#
# 用法：
#   scripts/bootstrap-project.sh --dry-run   # 只打印将会做什么
#   scripts/bootstrap-project.sh             # 幂等应用（可重复执行）
#   scripts/bootstrap-project.sh --check     # 只校验，存在漂移则退出码 1
#
# 凭据：需要 `.secrets/main.pat`（classic，scope: project + repo）。
#       官方明确 `GITHUB_TOKEN` 没有 projects 权限，所以 Actions 里也必须用 PAT 或 GitHub App。

set -eu
. "$(dirname "$0")/lib.sh"

PROJECT_CONFIG=".github/project/project.json"
FIELDS_CONFIG=".github/project/fields.json"
VIEWS_CONFIG=".github/project/views.json"
MAIN_PAT_FILE="${MAIN_PAT_FILE:-${SECRETS_DIR}/main.pat}"

MODE="apply"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --check)   MODE="check"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "未知参数：${1}（见 --help）" ;;
  esac
done

require_repo_root
require_cmd jq
for f in "$PROJECT_CONFIG" "$FIELDS_CONFIG" "$VIEWS_CONFIG"; do
  [ -f "$f" ] || die "缺少配置 ${f}"
  jq -e . "$f" >/dev/null || die "${f} 不是合法 JSON"
done

# ── 凭据 ────────────────────────────────────────────────────
if [ -z "${GH_TOKEN:-}" ]; then
  [ -s "$MAIN_PAT_FILE" ] || die "找不到 ${MAIN_PAT_FILE}。Projects 需要 classic PAT（scope: project + repo）；官方明确 GITHUB_TOKEN 无 projects 权限。"
  GH_TOKEN="$(cat "$MAIN_PAT_FILE")"
  export GH_TOKEN
fi
login="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$login" ] || die "凭据无法认证（是否已过期/被撤销？）"
case "${MODE}" in
  check)   info "模式：check（只校验）" ;;
  dry-run) info "模式：dry-run（只打印）" ;;
  *)       info "模式：apply（幂等应用）" ;;
esac
info "身份：${login}    仓库：${REPO}"

PROJECT_TITLE="$(jq -r '.title' "$PROJECT_CONFIG")"
export PROJECT_TITLE

gql() { gh api graphql -f query="$1" 2>/dev/null || true; }
# 查询 + 取字段；查询失败或结果为空时返回空串，而不是在 set -eu 下中断脚本
gqlj() { gql "$1" | jq -r "$2" 2>/dev/null || true; }

# JSON → GraphQL 输入对象字面量。
# ★ GraphQL 的输入对象**键必须是裸名**（name: 而不是 "name":），枚举值也不能带引号。
#   本次实现即因直接传 JSON 而全部失败：Expected NAME, actual: STRING ("name")。
json_to_gql() {
  sed -E -e 's/"([A-Za-z_][A-Za-z0-9_]*)":/\1:/g' -e 's/color:"([A-Z]+)"/color:\1/g'
}

# 用于**变更**：失败时返回非零并透出服务端报错。
# 注意 gql() 是容错版（吞掉错误），只能用于只读查询 —— 曾因此把失败误报为成功。
gql_strict() {
  local out
  if out="$(gh api graphql -f query="$1" 2>&1)"; then
    printf '%s' "$out"
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
}

drift=0

# ── ① 项目本体 ──────────────────────────────────────────────
info "① 项目：${PROJECT_TITLE}"
viewer_id="$(gqlj 'query{viewer{id login}}' '.data.viewer.id')"
PID="$(gqlj 'query{viewer{projectsV2(first:50){nodes{id title}}}}' '.data.viewer.projectsV2.nodes[] | select(.title==env.PROJECT_TITLE) | .id' | head -1)"

if [ -z "$PID" ]; then
  if [ "$MODE" = "check" ]; then
    warn "项目不存在（check 模式不创建）"; drift=$((drift + 1))
  elif [ "$MODE" = "dry-run" ]; then
    log "  [dry-run] 创建项目：${PROJECT_TITLE}"
    # 项目尚不存在时也要能完整预演后续步骤，故使用占位 id（只读查询会返回空，导致全部按"待创建"处理）
    PID="PVT_DRYRUN_PLACEHOLDER"
  else
    PID="$(gql "mutation{createProjectV2(input:{ownerId:\"${viewer_id}\",title:\"${PROJECT_TITLE}\"}){projectV2{id}}}" \
            | jq -r '.data.createProjectV2.projectV2.id')"
    ok "已创建项目（id=${PID}）"
  fi
else
  ok "项目已存在（id=${PID}）"
fi

if [ -n "$PID" ] && [ "$MODE" != "check" ] && [ "$MODE" != "dry-run" ]; then
  short_desc="$(jq -r '.shortDescription' "$PROJECT_CONFIG")"
  readme="$(jq -r '.readme' "$PROJECT_CONFIG")"
  gql "mutation{updateProjectV2(input:{projectId:\"${PID}\",shortDescription:$(printf '%s' "$short_desc" | jq -Rs .),readme:$(printf '%s' "$readme" | jq -Rs .)}){projectV2{id}}}" >/dev/null \
    && ok "描述与 README 已同步"
fi

if [ -z "$PID" ]; then
  warn "没有项目 id，后续步骤跳过"
  exit 1
fi

# ── ② 字段 ──────────────────────────────────────────────────
info "② 字段"
existing_fields="$(gqlj "query{node(id:\"${PID}\"){... on ProjectV2{fields(first:50){nodes{... on ProjectV2FieldCommon{id name}}}}}}" '.data.node.fields.nodes[]? | "\(.name)\t\(.id)"')"
printf '%s\n' "$existing_fields" | sed 's/^/    /' >&2

field_id_of() { printf '%s\n' "$existing_fields" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }

# 已存在的单选字段：确保选项集合与配置一致。
# ★ 关键：默认项目自带 Status(Todo/In Progress/Done)，而内置工作流（加入→Todo、关闭→Done、
#   合并→Done）指向的是**选项 id**。因此必须**保留 id、只改名称**（legacyRename 把旧名映射到新名），
#   否则那些工作流会指向已被删除的选项。
ensure_select_options() {
  local fid="$1" fj="$2" fname="$3"
  local cur_names want_names
  want_names="$(printf '%s' "$fj" | jq -r '.options[].name' | sort | tr '\n' '|')"
  cur_names="$(gqlj "query{node(id:\"${fid}\"){... on ProjectV2SingleSelectField{options{id name}}}}" '.data.node.options[]?.name' | sort | tr '\n' '|')"
  if [ "$cur_names" = "$want_names" ]; then
    ok "字段已存在且选项一致：${fname}"
    return 0
  fi
  if [ "$MODE" = "check" ]; then
    warn "字段 ${fname} 的选项与定义不一致（当前：${cur_names}）"
    drift=$((drift + 1))
    return 0
  fi
  if [ "$MODE" = "dry-run" ]; then
    log "  [dry-run] 更新字段选项：${fname}（${cur_names} → ${want_names}）"
    return 0
  fi

  local opts mut
  opts="$(gql "query{node(id:\"${fid}\"){... on ProjectV2SingleSelectField{options{id name}}}}" \
    | jq -c --argjson want "$(printf '%s' "$fj" | jq '.options')" --argjson rn "$(printf '%s' "$fj" | jq '.legacyRename // {}')" '
        (.data.node.options // []) as $cur |
        [ $want[] as $w |
          ( [ $cur[] | select(.name == $w.name or ((($rn[.name]) // "") == $w.name)) ] | first ) as $m |
          (if $m then {id: $m.id} else {} end)
          + {name: $w.name, color: $w.color, description: $w.description}
        ]')"
  [ -n "$opts" ] || { warn "无法构造 ${fname} 的选项列表"; drift=$((drift + 1)); return 0; }
  opts="$(printf '%s' "$opts" | json_to_gql)"
  mut="mutation{updateProjectV2Field(input:{fieldId:\"${fid}\",singleSelectOptions:${opts}}){projectV2Field{... on ProjectV2SingleSelectField{id name options{id name}}}}}"
  if gql_strict "$mut" >/dev/null; then
    ok "已更新字段选项：${fname}（保留原有选项 id）"
  else
    warn "更新字段选项失败：${fname}"
    drift=$((drift + 1))
  fi
}

START_DATE="${PROJECT_START_DATE:-$(date +%Y-%m-%d)}"
build_iterations_json() {
  local n="$1" dur="$2" d="$3" out="" i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    [ -n "$out" ] && out="${out},"
    out="${out}{\"title\":\"Iteration ${i}\",\"startDate\":\"${d}\",\"duration\":${dur}}"
    d="$(date_add_days "$d" "$dur")"
  done
  printf '[%s]' "$out"
}
date_add_days() {
  if date -j -v+"$2"d -f "%Y-%m-%d" "$1" +%Y-%m-%d >/dev/null 2>&1; then
    date -j -v+"$2"d -f "%Y-%m-%d" "$1" +%Y-%m-%d
  else
    date -d "$1 +$2 days" +%Y-%m-%d
  fi
}

total_fields="$(jq 'length' "$FIELDS_CONFIG")"
i=0
while [ "$i" -lt "$total_fields" ]; do
  fj="$(jq -c ".[$i]" "$FIELDS_CONFIG")"
  i=$((i + 1))
  fname="$(printf '%s' "$fj" | jq -r '.name')"
  ftype="$(printf '%s' "$fj" | jq -r '.dataType')"
  cur_fid="$(field_id_of "$fname")"
  if [ -n "$cur_fid" ]; then
    if [ "$ftype" = "SINGLE_SELECT" ]; then
      ensure_select_options "$cur_fid" "$fj" "$fname"
    else
      ok "字段已存在：${fname}（${ftype}）"
    fi
    continue
  fi
  if [ "$MODE" = "check" ]; then
    warn "缺少字段：${fname}（${ftype}）"; drift=$((drift + 1)); continue
  fi
  if [ "$MODE" = "dry-run" ]; then
    log "  [dry-run] 创建字段：${fname}（${ftype}）"
    continue
  fi

  opts=""
  if [ "$ftype" = "SINGLE_SELECT" ]; then
    opts="$(printf '%s' "$fj" | jq -c '[.options[] | {name: .name, color: .color, description: .description}]' | json_to_gql)"
    mut="mutation{createProjectV2Field(input:{projectId:\"${PID}\",dataType:SINGLE_SELECT,name:$(printf '%s' "$fname" | jq -Rs .),singleSelectOptions:${opts}}){projectV2Field{... on ProjectV2FieldCommon{id name}}}}"
  elif [ "$ftype" = "ITERATION" ]; then
    n_iter="$(printf '%s' "$fj" | jq -r '.iteration.iterations')"
    dur="$(printf '%s' "$fj" | jq -r '.iteration.duration')"
    iters="$(build_iterations_json "$n_iter" "$dur" "$START_DATE" | json_to_gql)"
    mut="mutation{createProjectV2Field(input:{projectId:\"${PID}\",dataType:ITERATION,name:$(printf '%s' "$fname" | jq -Rs .),iterationConfiguration:{startDate:\"${START_DATE}\",duration:${dur},iterations:${iters}}}){projectV2Field{... on ProjectV2FieldCommon{id name}}}}"
  else
    mut="mutation{createProjectV2Field(input:{projectId:\"${PID}\",dataType:${ftype},name:$(printf '%s' "$fname" | jq -Rs .)}){projectV2Field{... on ProjectV2FieldCommon{id name}}}}"
  fi

  if gql_strict "$mut" >/dev/null; then
    ok "已创建字段：${fname}（${ftype}）"
    existing_fields="$(gql "query{node(id:\"${PID}\"){... on ProjectV2{fields(first:50){nodes{... on ProjectV2FieldCommon{id name}}}}}}" \
      | jq -r '.data.node.fields.nodes[] | "\(.name)\t\(.id)"')"
  else
    warn "创建字段失败：${fname}（${ftype}）"; drift=$((drift + 1))
  fi
done

# ── ③ 视图 ──────────────────────────────────────────────────
info "③ 视图（过滤器需 create 后再 update；分组只能 UI 设置）"
existing_views="$(gqlj "query{node(id:\"${PID}\"){... on ProjectV2{views(first:50){nodes{id name layout filter}}}}}" '.data.node.views.nodes[]? | "\(.name)\t\(.id)\t\(.filter // "")"')"
view_id_of() { printf '%s\n' "$existing_views" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }
view_filter_of() { printf '%s\n' "$existing_views" | awk -F'\t' -v n="$1" '$1==n{print $3; exit}'; }

total_views="$(jq 'length' "$VIEWS_CONFIG")"
i=0
while [ "$i" -lt "$total_views" ]; do
  vj="$(jq -c ".[$i]" "$VIEWS_CONFIG")"
  i=$((i + 1))
  vname="$(printf '%s' "$vj" | jq -r '.name')"
  vlayout="$(printf '%s' "$vj" | jq -r '.layout')"
  vfilter="$(printf '%s' "$vj" | jq -r '.filter')"
  vfields="$(printf '%s' "$vj" | jq -r '.visibleFields[]?' | tr '\n' ' ')"
  vnote="$(printf '%s' "$vj" | jq -r '.manualNote // ""')"

  cur_vid="$(view_id_of "$vname")"
  if [ -n "$cur_vid" ]; then
    cur_filter="$(view_filter_of "$vname")"
    if [ "$cur_filter" = "$vfilter" ]; then
      ok "视图已存在且过滤器一致：${vname}（${vlayout}）"
    elif [ "$MODE" = "check" ]; then
      warn "视图 ${vname} 过滤器不一致：当前 '${cur_filter}' ≠ 定义 '${vfilter}'"
      drift=$((drift + 1))
    elif [ "$MODE" = "dry-run" ]; then
      log "  [dry-run] 更新视图过滤器：${vname}（'${cur_filter}' → '${vfilter}'）"
    elif gql_strict "mutation{updateProjectV2View(input:{viewId:\"${cur_vid}\",filter:$(printf '%s' "$vfilter" | jq -Rs .)}){projectV2View{id}}}" >/dev/null; then
      ok "已更新视图过滤器：${vname}"
    else
      warn "更新视图过滤器失败：${vname}"
      drift=$((drift + 1))
    fi
    [ "$vnote" != "无" ] && [ -n "$vnote" ] && log "    ↳ 需人工：${vnote}"
    continue
  fi
  if [ "$MODE" = "check" ]; then
    warn "缺少视图：${vname}"; drift=$((drift + 1)); continue
  fi
  if [ "$MODE" = "dry-run" ]; then
    log "  [dry-run] 创建视图：${vname}（${vlayout}）filter=${vfilter}"
    continue
  fi

  vid="$(gql_strict "mutation{createProjectV2View(input:{projectId:\"${PID}\",name:$(printf '%s' "$vname" | jq -Rs .),layout:${vlayout}}){projectV2View{id}}}" \
    | jq -r '.data.createProjectV2View.projectV2View.id')"
  if [ -z "$vid" ] || [ "$vid" = "null" ]; then
    warn "创建视图失败：${vname}"; drift=$((drift + 1)); continue
  fi

  ids=""
  for fn in $vfields; do
    fid="$(field_id_of "$fn")"
    [ -n "$fid" ] || continue
    [ -n "$ids" ] && ids="${ids},"
    ids="${ids}\"${fid}\""
  done
  cfg=""
  [ -n "$ids" ] && cfg=",configuration:{visibleFieldIds:[${ids}]}"
  if gql_strict "mutation{updateProjectV2View(input:{viewId:\"${vid}\",filter:$(printf '%s' "$vfilter" | jq -Rs .)${cfg}}){projectV2View{id}}}" >/dev/null; then
    ok "已创建视图并设置过滤器：${vname}"
  else
    ok "已创建视图：${vname}（过滤器设置失败，需人工核对）"
    drift=$((drift + 1))
  fi
  [ "$vnote" != "无" ] && [ -n "$vnote" ] && log "    ↳ 需人工：${vnote}"
done

# ── ④ 条目（把所有 open Issue 加入项目）────────────────────
info "④ 条目"
existing_items="$(gqlj "query{node(id:\"${PID}\"){... on ProjectV2{items(first:100){nodes{content{... on Issue{id}}}}}}}" '.data.node.items.nodes[]?.content.id? // empty')"
open_ids="$(gh issue list -R "$REPO" --state open --limit 200 --json id,number --jq '.[] | "\(.id)\t\(.number)"')"
added=0; skipped=0
while IFS="$(printf '\t')" read -r iid inum; do
  [ -n "$iid" ] || continue
  if printf '%s\n' "$existing_items" | grep -qx "$iid"; then
    skipped=$((skipped + 1)); continue
  fi
  if [ "$MODE" = "check" ]; then
    warn "Issue #${inum} 尚未加入项目"; drift=$((drift + 1)); continue
  fi
  if [ "$MODE" = "dry-run" ]; then
    log "  [dry-run] 加入条目：Issue #${inum}"; continue
  fi
  if gql_strict "mutation{addProjectV2ItemById(input:{projectId:\"${PID}\",contentId:\"${iid}\"}){item{id}}}" >/dev/null; then
    added=$((added + 1))
  else
    warn "加入失败：Issue #${inum}"; drift=$((drift + 1))
  fi
done <<EOF
${open_ids}
EOF
ok "条目：新增 ${added}，已在库 ${skipped}"

# ── ⑤ 内置自动化：API 无法开启，只能检测并提示 ──────────────
info "⑤ 内置自动化（**官方限制：无法通过 API 开启**，必须 UI 手工）"
wf="$(gqlj "query{node(id:\"${PID}\"){... on ProjectV2{workflows(first:20){nodes{name enabled}}}}}" '.data.node.workflows.nodes[]? | "    \(if .enabled then "✅ 已启用" else "⬜ 未启用" end)  \(.name)"')"
if [ -z "$wf" ]; then
  warn "读不到任何工作流（可能尚未初始化）"
else
  printf '%s\n' "$wf" >&2
fi
log "  ↳ 若上面有未启用项，请按 docs/PLAYBOOK.md §9 在 UI 开启（本项目需要：加入→Todo、关闭→Done、合并→Done、状态改变→关单）"

echo
if [ "$MODE" = "check" ]; then
  if [ "$drift" -eq 0 ]; then ok "无漂移"; exit 0; fi
  warn "存在 ${drift} 项漂移 —— 运行 scripts/bootstrap-project.sh 修复（视图分组与内置自动化仍需人工）"
  exit 1
fi
if [ "$drift" -eq 0 ]; then
  ok "完成（幂等，可重复执行）"
else
  warn "完成，但有 ${drift} 项未成功 —— 见上方提示"
  exit 1
fi
