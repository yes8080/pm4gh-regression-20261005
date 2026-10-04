# 规则集即代码（Rulesets as code）

`main-protection.json` 是**目标态**，不是第一步就应用的配置。原因见方案 §1.2.1：

- 个人 Pro **没有 `evaluate` 评估态**（官方：仅 GitHub Enterprise），无法"先灰度观察"；
- 一旦规则集要求审批或必需检查而对应条件不满足，**所有 PR 都会合不进去**（死锁）。

因此必须**渐进加严**，每一步都用一次真实 PR 验证后再进入下一步（该工作属切片 #4）。

## 实施状态：已上线（2026-10-04，切片 #4）

| 项 | 值 |
|---|---|
| ruleset id | `24442991` |
| 名称 / 目标 / 状态 | `main-protection` / `branch` / `active` |
| 目标引用 | `~DEFAULT_BRANCH`（**不是** `**`，否则切片分支合并后无法自动删除） |
| bypass 名单 | **空** —— 无人可绕过，包括管理员 |
| 已启用规则 | `deletion`、`non_fast_forward`、`required_linear_history`、`required_status_checks`（strict，6 个 context）、`pull_request`（approvals=1、CODEOWNERS 评审、驳回陈旧批准、最后推送者之外批准、必须解决评论、仅允许 squash） |
| 线上 vs `main-protection.json` | 一致 |

### 实施过程中被验证的事实（均有原始输出为证）

1. **`git push --dry-run` 不能用来判断规则集是否生效。**
   阶段 1（仅必需检查 + 禁强推/禁删除/线性历史）时 dry-run 显示"可以推送 `HEAD -> main`"，但 dry-run 并不评估 repository rules —— 这是个**假信号**，差点让我们误判阶段 1 已禁止直推。
2. **阶段 2 加入 `pull_request` 规则后，真实直推被服务端拒绝**，原始报错：
   ```
   remote: - 6 of 6 required status checks are expected.
   remote: - Changes must be made through a pull request.
   ! [remote rejected] HEAD -> main (push declined due to repository rule violations)
   ```
   → 结论：**`pull_request` 规则是"禁止直推"的真正来源**；`required_status_checks` 约束的是合并路径，不是 push。
3. 拒绝后 `main` 未发生任何变化（整次推送被服务端整体拒绝）。

### 门禁生效后的日常影响（必读）

- 所有改动必须经 PR。PR 必须同时满足：6 个必需检查全绿 + 与 `main` 同步（strict）+ **至少 1 名非作者授权身份批准** + CODEOWNERS 批准 + 无未解决评论 + 仅 squash 合并。
- **作者无法自我批准**（GitHub 平台限制），因此 `@yes8080-reviewer-bot` 凭据可用性是**硬依赖**：凭据失效即无法合并。回退手段是删除规则集（见文末「回退」）。
- 推新提交会**驳回已过期的批准**，返修后必须重新评审（`dismiss_stale_reviews_on_push` + `require_last_push_approval`）。
- 未来若启用 Merge Queue（官方门控：私有仓库需 GHEC），必须把 `qa/acceptance` 接入 `merge_group` 事件，否则合并队列会因必需检查未上报而卡死。

> 注：下文保留的是**应用前的参考手册**（分阶段 payload 与命令）。当前线上状态以上表为准；后续若要改规则，按 §4 三阶段流程走，不要在已启用状态下整份覆盖。

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
