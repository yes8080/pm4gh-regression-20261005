# 规则集即代码（Rulesets as code）

`main-protection.json` 是**目标态**，不是第一步就应用的配置。原因见方案 §1.2.1：

- 个人 Pro **没有 `evaluate` 评估态**（官方：仅 GitHub Enterprise），无法"先灰度观察"；
- 一旦规则集要求审批或必需检查而对应条件不满足，**所有 PR 都会合不进去**（死锁）。

因此必须**渐进加严**，每一步都用一次真实 PR 验证后再进入下一步（该工作属切片 #4）。

## 官方事实（应用时必须遵守）

| 事项 | 官方结论 |
|---|---|
| `gh ruleset` 能力 | 本机 CLI **只有 `check` / `list` / `view`（只读）**，没有 create/edit/delete |
| 写入方式 | REST：`POST/PUT /repos/{owner}/{repo}/rulesets`（读需 `Metadata:read`，写需 `Administration:write`）、UI 的 JSON 导入、或 Terraform `github_repository_ruleset` |
| 必需检查未上报 | 检查**永久 pending**，PR 卡死；被 paths/branches 过滤跳过的工作流会造成这种结果 |
| 必需检查可选条件 | 该检查须**近 7 天内在本仓库成功过**才能被选为必需项 |
| 检查名格式 | 普通工作流为 `<job name>`；可复用工作流为 `<job name> / <reusable job name>` |
| 触发事件限制 | 只有 `push` / `pull_request` / `pull_request_review` / `pull_request_target` / `deployment` / `deployment_status`（合并队列再加 `merge_group`）触发的检查才算数；`workflow_dispatch` 不算 |
| 分支通配风险 | 规则集目标不得用 `**`，否则与"自动删除头分支"冲突 |

## 分阶段应用（每步都要有一次真实 PR 证据）

### 阶段 1：只上必需状态检查（strict）

前提：#3 的 CI 检查已在真实 PR 上成功上报过（≥1 次）。

```bash
gh api -X POST repos/yes8080/pm4gh/rulesets --input - <<'JSON'
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "required_status_checks", "parameters": {
        "do_not_enforce_on_create": false,
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "ci/lint" }, { "context": "ci/test" },
          { "context": "policy/linked-issue" }, { "context": "policy/branch-name" },
          { "context": "policy/template" }, { "context": "qa/acceptance" }
        ] } }
  ]
}
JSON
```

验证：开一个真实 PR，确认必需检查正常出现并能通过，`gh pr merge --squash --delete-branch` 成功、头分支被删。

### 阶段 2：加 PR 审批（本步是本方案唯一需要"独立身份"才能过的门）

前提：`@yes8080-reviewer-bot` **已接受 collaborator 邀请**（否则无人有资格批准 → 死锁）。

```bash
ID=$(gh api repos/yes8080/pm4gh/rulesets --jq '.[] | select(.name=="main-protection") | .id')
gh api -X PUT repos/yes8080/pm4gh/rulesets/$ID --input - <<'JSON'
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"] } },
    { "type": "required_status_checks", "parameters": {
        "do_not_enforce_on_create": false,
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "ci/lint" }, { "context": "ci/test" },
          { "context": "policy/linked-issue" }, { "context": "policy/branch-name" },
          { "context": "policy/template" }, { "context": "qa/acceptance" }
        ] } }
  ]
}
JSON
```

验证：用 bot 身份 `gh pr review <n> --approve`，确认 PR 变为可合并；作者自己 approve 必须无效。

### 阶段 3：`main-protection.json` 与线上一致后固化

```bash
gh api repos/yes8080/pm4gh/rulesets > /tmp/live-rulesets.json
gh ruleset list -R yes8080/pm4gh
gh ruleset check main -R yes8080/pm4gh     # 预演哪些规则会命中
```

将线上结果与 `main-protection.json` 对比后再合并本文件更新。

## 回退

```bash
ID=$(gh api repos/yes8080/pm4gh/rulesets --jq '.[] | select(.name=="main-protection") | .id')
gh api -X DELETE repos/yes8080/pm4gh/rulesets/$ID
```

> 官方限制提醒：合并队列（`merge_queue`）与"要求部署成功"（`required_deployments`）**只能建在仓库级规则集**，组织级规则集不支持；且 Merge Queue 本身在"私有 + 非 GHEC"套餐下不可用，本方案不依赖它。
