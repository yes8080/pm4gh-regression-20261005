# PLAYBOOK — 操作手册（人与 AI 工具都照此执行）

> **定位**：本文件是本项目**唯一的流程权威**。任何工具、任何人（含 AI Agent）接手时，
> 只读本文件 + 用 `git`/`gh`，就应当能独立完成：领切片 → 建分支 → 交付 PR → 独立评审 → 验收 → 合并 → 收尾。
> 如果你的工具与本文冲突，**以本文为准**；如果本文与 GitHub 平台实际行为冲突，**先修本文再干活**。
>
> 相关文件：[GOVERNANCE.md](GOVERNANCE.md)（规则与决策）｜[AGENTS.md](../AGENTS.md)（AI 工具契约）｜[TOOLING.md](../TOOLING.md)（工具接入与切换）｜[项目管理方案.md](项目管理方案.md)（设计依据与官方引用）

---

## 1. 三条铁律

1. **状态只在 GitHub。** 本地不得存在"只有某个工具知道"的进度（个人 TODO 文件、IDE 任务列表、聊天记录里的计划）。
2. **流程只在仓库里。** 流程 = 本文件 + `.github/**` + `scripts/**`。工具不引入自己的流程。
3. **一切可脚本化、可幂等。** 每个步骤都有对应命令；无法脚本化的动作必须登记在 §9「人工步骤清单」并说明原因。

---

## 2. 接手项目第一步（必做）

```bash
git clone https://github.com/yes8080/pm4gh.git && cd pm4gh
scripts/toolcheck.sh          # 8 项自检：命令/gh 登录/规则集漂移/必需检查/凭据/git 远端
```

**任何一项未通过都不要开始干活。** 最常见的两类失败：

| 现象 | 原因 | 处理 |
|---|---|---|
| 凭据文件不存在或权限不是 600 | 没有 `.secrets/reviewer.pat` | 见 §3 |
| 线上规则集与仓库定义不一致 | 有人手动改过规则集 | `scripts/audit.sh` 查看差异；按 §9 规则集流程修正 |

---

## 3. 凭据（身份与权限）

本项目用**两个身份**模拟真实团队的评审独立性（决策 D2）：

| 身份 | 用途 | 凭据形式 | 存放 |
|---|---|---|---|
| 主身份 `yes8080` | 实现、治理、合并、发布 | 本机 `gh auth login`（`repo` scope 足够） | 系统钥匙串 |
| 评审/验收身份 `yes8080-reviewer-bot` | 独立评审、`/accept` 记录 | **classic PAT，只勾 `repo`** | `.secrets/reviewer.pat`（0600，已 gitignore） |

> **D9 后已不再需要 `project` scope 的凭据**：Projects 已移除，主身份只用 `gh` 登录（`repo` scope）即可。
> 若你此前签发过带 `project` 的 token（`.secrets/main.pat`），**建议立即在 GitHub 上撤销**（本仓库已删除该文件）。

**为什么必须是 classic 而不是 fine-grained**（官方限制，见 附录 C.3）：
fine-grained PAT **无法**用于"用户作为 repository collaborator 的仓库"，也**无法**访问"用户账号拥有的 Projects"—— 本项目两条都踩中。

**使用方式**（脚本已封装，手工操作时照此）：

```bash
# 主身份（作者）：不要设置 GH_TOKEN
unset GH_TOKEN

# 评审身份
export GH_TOKEN="$(cat .secrets/reviewer.pat)"
gh api user --jq .login        # 应输出 yes8080-reviewer-bot
unset GH_TOKEN                 # 用完立刻切回主身份
```

**铁律**：凭据永不入库、永不写进 Issue/PR 正文、永不打印。
`require_code_owner_review` 生效后，评审身份凭据是 `.github/`、`scripts/`、`docs/` 改动的**唯一**非作者评审人 —— 它失效 = 这些路径无法合并（`scripts/toolcheck.sh` 会提前发现）。

---

## 4. 环境陷阱（本项目已实际踩到，务必内化）

| 陷阱 | 现象 | 规则 |
|---|---|---|
| **macOS bash 3.2 吞变量名后的多字节字符** | `echo "$X（中文）"` 报 `unbound variable`，但 `bash -x` 下正常 | 变量后紧跟中文必须写 `${VAR}`（已踩 3 次，`ci/lint` 常驻检查） |
| **bash 4 特性在 macOS 失败** | `mapfile`/`readarray`/`declare -A`/`${var,,}` 不可用 | 只用 bash 3.2 语法（`ci/lint` 常驻检查） |
| **BSD sed 不支持 BRE 的 `\+`** | `sed 's/[^a-z]\+/-/g'` 静默失效，替换没发生 | 一律用 `sed -E` |
| **`git push --dry-run` 不评估 repository rules** | 规则集已禁止直推，但 dry-run 显示"可以推送" | **不要用它判断门禁是否生效**；用真实推送或 `gh ruleset check` |
| **`gh issue create` 没有 `--json`** | 报 `unknown flag: --json` | 用 `gh issue create ... \| tail -1` 取 URL，再 `${URL##*/}` 取号 |
| **`gh` 没有 `milestone` 子命令** | `unknown command "milestone"` | 分配用 `--milestone "名称"`；CRUD 用 `gh api /repos/{o}/{r}/milestones` |
| **`gh ruleset` 只读** | 只有 `check`/`list`/`view` | 写规则集用 `gh api -X POST/PUT --input` 或 UI 的 JSON 导入 |
| **`gh project` 需要 `project` scope** | 报 `missing required scopes` | 用 `.secrets/main.pat`（`GH_TOKEN=...`），不要试图靠 `gh auth refresh`（本机钥匙串会失败） |
| **Issue Types 在个人仓库不可用** | REST 列表端点**会返回默认值**（假阳性），但 `gh issue edit --type` 报无可用类型 | 用 `type/*` 标签；判定可用性要看**写入**能力，不要看 REST 列表 |
| **关闭关键字只在 PR 正文/提交信息生效** | 写在 PR 标题里无效 | 正文必须显式 `Closes #N`；**PR 目标不是默认分支时全部失效** |
| **`gh pr create --fill` 会丢正文** | 多提交时只带提交标题 | 用 `--body-file`（`scripts/deliver.sh` 已强制） |
| **squash 合并后 `git branch -d` 拒绝删分支** | 原始提交不在 main 上，git 祖先判定失效 | 先验证 `gh pr view <n> --json state` 为 `MERGED`，再用 `-D`（`scripts/closeout.sh` 已封装） |
| **`blockedBy` 不因对方关闭而清除** | 阻塞项关闭了，关系仍挂着 | 判断是否被阻塞**只看 blocker 的 `state`**；`scripts/audit.sh` 会报"可解锁" |
| **GraphQL 输入对象的键必须是裸名** | `{"name":"x"}` → `Expected NAME, actual: STRING ("name")` | 传 GraphQL 字面量 `{name:"x"}`（本项目 `json_to_gql` 已封装） |
| **状态标签必须唯一** | 多个 `status/*` 标签会让状态不可判定 | 只用 `scripts/status.sh` 迁移；`ci/test` 会扫描全部开放 Issue 并在违规时失败 |
| **source 阶段残留失效 `GH_TOKEN`** | `GH_TOKEN=bogus bash scripts/audit.sh` 会在 `source lib.sh` 时直接失败（`[FAIL] 无法确定仓库`），因为 `REPO` 在 source 阶段解析 | 已在 `lib.sh` 修复：解析时临时清空 `GH_TOKEN` 再恢复。**排查时**注意"脚本还没开始跑就失败"通常属这类 source 阶段问题 |
| **BSD `grep` 不支持 `-P`** | 本机复现 `ci/lint` 的 `grep -nHP` 检查时会报非法选项 | 本地用 Python 等价正则复算，最终以 CI 的 `ci/lint` 结果为准；不要因本地跑不了就跳过 |
| **陈旧的 remote-tracking ref** | 合并后 `git branch -a` 仍列出已删除的远程分支 | `git fetch --prune`。判定远程分支是否存在**必须用 `git ls-remote`**（`closeout.sh` 即如此），不要看 `git branch -r` |
| **同一 workspace 只允许一个执行者** | 两个执行者并发会互相删分支/切 HEAD（本项目已实际发生：演练执行者的分支被我清理时被切走，它靠悬空 commit 恢复） | 交接必须显式"让出"：确认对方工作区干净且已切回 `main` 后再动手；并行应使用独立 clone/worktree |
| **环境里残留失效的 `GH_TOKEN` 会让所有脚本在 source 阶段就失败** | `lib.sh` 在 **source 时**（早于 `use_main_identity`）就用 `gh repo view` 解析 `REPO`，失效 token → 报"无法确定仓库" | 要强制主身份的脚本需在 `source lib.sh` **之前** `unset GH_TOKEN`（`scripts/report.sh` 已如此处理）；排查时先 `unset GH_TOKEN` |

---

## 5. 端到端工作流

> 状态机取值：`Backlog / Ready / In Progress / In Review / Acceptance / Rework / Done / Canceled`
> 状态由 `status/*` 标签 + Issue 开关状态承载（决策 D9）；`scripts/status.sh` 是唯一迁移入口

### W0 仓库基线（仅建仓时一次）
```bash
gh repo edit --delete-branch-on-merge --enable-auto-merge \
  --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false
scripts/sync-labels.sh                     # 标签即代码（幂等，不删存量）
# 规则集：见 §9「规则集分阶段应用」
```

### W0.5 状态机与视图（决策 D9：Projects 已移除）

**状态源 = `status/*` 标签 + Issue 开关状态 + Milestone**（全部可 API 化，无手工步骤）。

```bash
scripts/status.sh <issue#> <state>     # 唯一合法迁移入口
scripts/status.sh <issue#> --show      # 查当前状态
scripts/status.sh --check              # 扫描全部开放 Issue 的互斥性与合法性
```

| 状态 | 载体 |
|---|---|
| `backlog` | OPEN 且无 `status/*` 标签 |
| `ready` / `in-progress` / `in-review` / `acceptance` / `rework` | 对应 `status/*` 标签 |
| `done` | Issue CLOSED（`state_reason=completed`） |
| `canceled` | Issue CLOSED（`state_reason=not planned`） |

**集成点**（一般不需要手工调用）：`start.sh`→`in-progress`；`deliver.sh`→`in-review`；
`review.sh approve`→`acceptance`；`review.sh request-changes|reject`→`rework`；`closeout.sh` 核验清理。

**原 8 个 Projects 视图的等价搜索**（任一工具都能用）：

```bash
gh issue list -R yes8080/pm4gh --search 'label:status/in-review'                # Review Desk
gh issue list -R yes8080/pm4gh --search 'label:status/acceptance'               # Acceptance Desk
gh issue list -R yes8080/pm4gh --search 'label:status/ready' --assignee @me     # My Queue
gh issue list -R yes8080/pm4gh --search 'label:status/rework'                   # 返修队列
gh issue list -R yes8080/pm4gh --search 'is:open -label:status/ready,...'       # 就绪前
gh issue list -R yes8080/pm4gh --milestone "M1 自举流程骨架"                     # 里程碑进度（原生页面）
gh api repos/yes8080/pm4gh/milestones --jq '.[] | "\(.title) \(.closed_issues)/\(.open_issues+\(.closed_issues))"'  # 燃尽
```
**度量出口**（`scripts/report.sh`，只读；替代已随 D9 移除的 Projects Insights）：

```bash
scripts/report.sh                      # 最近 30 天，按周聚合（默认）
scripts/report.sh --days 7             # 换窗口
scripts/report.sh --group-by day       # 按日聚合
scripts/report.sh --json | jq .        # 机器可读：stdout 只有 JSON，可安全接管道
```

实测输出（2026-10-04T05:06:09Z，repo=yes8080/pm4gh，仅主身份 `gh` 登录凭据）：

```text
[INFO] 只读读取：repo=yes8080/pm4gh 窗口=最近 30 天（since 2026-09-04）聚合=week
pm4gh 度量报告
仓库：yes8080/pm4gh   窗口：最近 30 天（since 2026-09-04）   聚合：week
生成时间：2026-10-04T05:06:09Z   （只读；口径见 docs/GOVERNANCE.md §8）

① 在途（开放 Issue 按 status/* 分组；backlog = 无 status/* 标签）
status/in-progress   1 个
      #27  [E1-S11] scripts/report.sh：用搜索 API 替代 Projects Insights 的度量出口
backlog（无 status/* 标签）   3 个
      #1  [E1] 自举流程骨架
      #8  [E1-S7] 工具切换演练（本 Epic 终验）
      #23  [Chore] 删除已废弃的 GitHub Projects 对象（仅 PM 可执行）
  合计 4 个

② 吞吐（窗口内已关闭且 state_reason=completed；按周聚合）
  2026-W40 (09-28~10-04)   11 个   #2 #3 #4 #5 #6 #7 #10 #13 #15 #22 #25
  合计 11 个

③ 返修率（分子＝带 src/rework 的 Issue 数；分母＝窗口内已关闭 Issue 数）
  带 src/rework 的 Issue：0 个（其中窗口内已关闭：0 个）
  窗口内已关闭：11 个
  返修率 = 0 / 11 = 0%
```

口径与边界（**口径唯一来源仍是 [GOVERNANCE §8](GOVERNANCE.md)**，`report.sh` 只做只读聚合，不写任何状态）：

- 在途按 `status/*` 标签分组，`backlog` = 开放且无 `status/*` 标签；同时把"多个/非法 `status/*` 标签"
  归为 `违反不变量` 并在 **stderr** 告警（状态必须唯一，用 `scripts/status.sh` 修正）。
- 吞吐只统计 `state_reason=completed`；`not planned`（`Canceled`）不计入。
- 返修率分子取"带 `src/rework` 的 Issue 数"，分母取"窗口内已关闭 Issue 数"（Issue #27 验收标准）；
  §8 原文的"总切片"分母（是否把 Epic/Chore 计入）未在脚本中展开，如需收紧另开切片。
- 数据质量告警（结果被 `--limit` 截断、状态标签违反不变量）一律写 stderr，**不污染 `--json` 的 stdout**；
  失败（参数非法、jq 缺 `strftime`）直接以非零退出，不静默降级。

GitHub 仓库级"保存视图"（2026-09 GA）可作人工便利层。

### W1 里程碑立项
```bash
gh api -X POST repos/{owner}/{repo}/milestones \
  -f title="M1 名称" -f due_on="2026-10-25T00:00:00Z" -f description="…"
```
判定：里程碑有明确目标、验收口径、范围外事项、目标日期。

### W2 Epic 与切片立项
```bash
# Epic（子 Issue 的父级）
gh issue create --title "[E2] 名称" --label type/feature --milestone "M1 名称" --body-file epic.md
# 切片（一个切片 = 一个 Issue = 一个分支 = 一个 PR）
gh issue create --parent <epic#> --title "[E2-S3] 名称" \
  --label type/task,role/dev --milestone "M1 名称" --body-file slice.md
# 依赖（注意：blockedBy 不会自动清除）
gh issue edit <slice#> --add-blocked-by <other#>
```
判定：切片满足 DoR 五项（价值/验收标准/边界/依赖/估算与归属）。

### W2.5 就绪判定（谁把切片从 Backlog 置为 Ready）

**首次工具切换演练暴露的缺口**：早期文档只说"DoR 满足 → Ready"，但**没有写明由谁执行**。
现明确：**PM（或自领者本人，需在 Issue 中说明）** 在 DoR 五项齐全后执行：

```bash
scripts/status.sh <issue#> ready
```

同时补齐正交维度标签（可叠加，与状态不互斥）：

```bash
gh issue edit <issue#> --add-label "prio/P1,size/3"
```

> 维度分工（方案 §2.4）：`status/*` = 状态（**互斥**，唯一迁移入口 `status.sh`）；
> `prio/*`、`size/*`、`area/*`、`role/*`、`risk/*`、`src/*` = 正交维度（**可叠加**）。

### W3 领取与开工
```bash
scripts/start.sh <issue#>                      # 推荐
# 等价手工命令：
gh issue develop <issue#> --base main --name slice/<issue#>-<slug> --checkout
gh issue edit <issue#> --add-assignee @me
scripts/status.sh <issue#> in-progress      # 状态迁移（start.sh 已自动执行）
```
**必须用 `gh issue develop`**：手工 `git checkout -b` 不会建立 Issue ↔ 分支绑定，Issue 的 Development 区块不显示分支。

### W4 开发与提交
```bash
# Conventional Commits + Issue 号
git commit -m "feat(scope): 说明 (#123)"
bash -n scripts/*.sh        # 若改了脚本
```

### W5 交付 PR
```bash
scripts/deliver.sh <issue#> --prepare    # 生成六段正文骨架到 .git/PR_BODY_<n>.md
# 填写骨架（六段都要有实质内容）
scripts/deliver.sh <issue#>              # 校验并创建 PR
```
判定：正文含 `Closes #<issue#>`；六段齐备；工作区干净；分支名合规。
`deliver.sh` 会自动把状态迁到 `in-review`。

### W6 独立评审
```bash
scripts/review.sh <pr#> approve --body-file review.md
# 或
scripts/review.sh <pr#> request-changes --body-file rework-list.md
```
判定：**评审身份 ≠ 作者**；`request-changes` 必须给出**可逐条核对的返修清单**。

### W7 验收
```bash
scripts/review.sh <pr#> accept --body-file acceptance.md    # 通过：留 /accept 记录
scripts/review.sh <pr#> reject --body-file gaps.md          # 不通过：留 /reject + 差距
```
**状态迁移**：`review.sh approve` 自动置 `acceptance`；`request-changes` / `reject` 自动置 `rework`。

**重要（能力边界）**：`/accept` 是**人工审计证据，不是合并阻塞条件**。官方限制导致它无法机器化：
- `issue_comment` 触发的检查**不满足**必需检查；
- 必需检查**不能"先失败后通过"**（Bug #13 实测：会让 PR 永久 BLOCKED）。
真正的合并门禁是规则集原生规则：`required_approving_review_count` + `require_last_push_approval`。
因此执行顺序是：**先 approve（解锁合并），再留 /accept（存档证据）**。

### W8 合并与收尾
```bash
gh pr merge <pr#> --squash --delete-branch
scripts/status.sh <issue#> done   # GitHub 已用 Closes #N 自动关单；此步清理残留的 status/* 标签（幂等）
scripts/closeout.sh <pr#>         # 五项核验：已合并 / Issue 已关 / 远程分支已删 / 本地已清理 / 无残留状态标签
```
判定：**五项**全过（已合并 / Issue 已关 / 远程分支已删 / 本地已清理 / 关闭后无遗留 `status/*` 标签）。
`closeout.sh` 会在未合并时**拒绝**删除本地分支。

### W9 返修（评审/验收未通过）
1. **不新建分支、不新建 PR**：在原切片分支继续提交。
2. 新提交会**驳回已有批准**（`dismiss_stale_reviews_on_push`）→ 必须重新评审。
3. 挂 `src/rework` 标签用于统计返修率。
4. **返修上限 2 次**；第 3 次打回必须升级为"切片重切"或"需求澄清"，由 PM 决策并记录。

### W10 Bug 修复
| 场景 | 处理 |
|---|---|
| 切片未合并时发现缺陷 | 在原分支修复，走 W9 |
| 切片已合并后（开发期） | 新建 Bug Issue（含复现/期望/实际/影响版本）→ `fix/<issue#>` 分支 → PR 写 `Fixes #N` |
| 线上故障 | 新建 Bug Issue 标 `P0` → `hotfix/<issue#>` 从 main 拉 → 走完整门禁；**目标非默认分支时需手动关单** |

### W11 交接（换工具/换人）
见 [TOOLING.md](../TOOLING.md) 的交接块结构。核心：把「分支 / 已完成 / 未完成 / 阻塞 / 本地是否有未推送提交」写进 Issue 评论。

### W12 发布
```bash
gh release create v<x.y.z> --generate-notes
```
发布后：Milestone 关闭；未完成切片**显式迁移**到下一 Milestone，不允许静默留在旧里程碑。

---

## 6. 门禁清单（合并一个 PR 必须同时满足）

| 门禁 | 来源 | 说明 |
|---|---|---|
| 5 项必需检查全绿且与 main 同步（strict） | 规则集 `required_status_checks` | `ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template` |
| ≥1 名非作者授权身份批准 | 规则集 `required_approving_review_count=1` | 作者无法自我批准（平台拒绝） |
| CODEOWNERS 批准 | 规则集 `require_code_owner_review` | 见 §7 硬规则 2 |
| 无未解决评审评论 | `required_review_thread_resolution` | |
| 仅 squash 合并 | `allowed_merge_methods` | `main` 保持线性历史 |
| 禁止直推 / 强推 / 删除 main | `pull_request` + `non_fast_forward` + `deletion` | 已用真实推送验证 |
| （审计，非阻塞）`qa/acceptance` | 独立工作流 | 显示"是否已有授权身份批准"，供人工核对 |

---

## 7. 两条硬规则（违反会造成 PR 永久卡死）

### 规则 1：必需状态检查绝不能"先失败后通过"
同一 commit SHA 上只要留下过一次失败结论，后续同名检查通过**也无法**解除阻塞（Bug #13 实测，含实验 A/B 对照）。
→ 任何"需要事后复检才能通过"的判据（如验收）**不得**设为必需检查。必需检查必须是"打开 PR 时就能判定"的静态规则。

### 规则 2：CODEOWNERS 里任何会被改动的路径，都必须有至少一个"非作者"的 owner
若某路径 owner 只有作者本人，`require_code_owner_review` 会让该路径**永久无法合并**（作者不能自我批准）。
且 **CODEOWNERS 取自目标分支** —— 在 PR 里改它无法为该 PR 解锁，只能先降级规则集（代价高）。
本仓库所有规则统一写成 `@yes8080 @yes8080-reviewer-bot`。

---

## 8. 故障处置：PR 卡住了怎么排查

```bash
gh pr view <pr#> --json reviewDecision,mergeStateStatus     # 先看两个字段
gh pr checks <pr#> --required                                # 必需检查是否齐、是否 pending
gh api repos/{o}/{r}/commits/<head-sha>/check-runs --jq '.check_runs[] | "\(.name) \(.conclusion)"'
```

| 症状 | 常见根因 | 处理 |
|---|---|---|
| `mergeStateStatus: BLOCKED` + `reviewDecision: APPROVED` | 同 SHA 上有失败的必需检查（规则 1） | 修正该检查设计；应急时从必需清单移除并记录 |
| `BLOCKED` + `REVIEW_REQUIRED` | 尚无授权身份批准，或缺 code-owner 批准 | `scripts/review.sh <pr#> approve` |
| 某项必需检查**永久 pending** | 工作流被 `paths`/`branches` 过滤跳过；或检查名被改名 | 去掉过滤；比对 `scripts/toolcheck.sh` 的"必需检查 ↔ 工作流 job"检查 |
| `mergeStateStatus: UNSTABLE` | **不是卡点**：表示存在非必需的失败/待定检查（本项目即 `qa/acceptance` 这条审计检查）。只要 `reviewDecision=APPROVED` 且必需检查全绿，**可以合并** | 直接 `gh pr merge`；只有 `BLOCKED` 才需要按上表定位 |
| `gh pr merge` 报 `base branch policy prohibits the merge` | 上述任一未满足 | 按上表定位；**不要**用 `--admin`（bypass 名单为空） |
| 直推 main 被拒 | 规则集生效，符合预期 | 改建分支走 PR |

---

## 9. 人工步骤清单（无法脚本化，或涉及不可逆操作）

| 步骤 | 为什么必须人工 | 具体做法 |
|---|---|---|
| 接受 collaborator 邀请 | 需以被邀请账号登录 | 用 `yes8080-reviewer-bot` 打开 `https://github.com/yes8080/pm4gh/invitations` |
| 签发/轮换 PAT | 需在目标账号的浏览器会话中操作 | classic token；reviewer 勾 `repo`；main 勾 `repo`+`project`；写入 `.secrets/<name>.pat` 后 `chmod 600` |
| **规则集分阶段应用** | 一把覆盖会让所有 PR 卡死 | 见下 |
| **规则集应急回退** | 唯一的"开门"手段 | `gh api -X DELETE repos/yes8080/pm4gh/rulesets/24442991` |
| **必需检查改名** | 改名会让所有 PR 永久 pending | ①规划新名 ②同时改工作流 job 名与规则集 context（先加后删，避免空窗）③合并后立刻验证新检查上报 ④更新本文与 `.github/rulesets/README.md` |
| 签发 Release | 涉及对外发布 | `gh release create v<x.y.z> --generate-notes`，并核对 Milestone |

> **已完成的人工步骤（历史记录）**
> · **删除已废弃的 Projects 对象**：2026-10-04 已于 Issue #23 执行完毕（`PM4GH 交付看板`，实际地址 `users/yes8080/projects/4`，非 `/1`）。
>   本项目此后不再依赖任何 Projects。
> · **经验更正**：钥匙串修复并重新授权后，`gh` 登录凭据**已可用 `project` scope**（`gh auth status` 可见 `project`）。
>   因此"操作 Projects 必须另签 PAT"的旧结论**已不成立** —— 当时是钥匙串缺陷导致的误判。保留此条以免将来重犯。

**规则集分阶段应用**（个人 Pro 无 `evaluate` 灰度态，只能逐步加严）：
1. 只上 `required_status_checks`（strict）+ `deletion` + `non_fast_forward` + `required_linear_history`
2. 用真实 PR 验证 5 项检查都能正常上报并通过
3. 追加 `pull_request`（审批数、CODEOWNERS、驳回陈旧批准、最后推送者之外批准、解决评论、仅 squash）
4. 用一个触碰 `.github/` 的 PR 验证 code-owner 链路（必须实测，不能只读 CODEOWNERS 推断）
5. 用 `gh api repos/{o}/{r}/rulesets/<id>` 核对线上与 `.github/rulesets/main-protection.json` 一致

---

## 10. bootstrap 例外（已知的历史豁免）

仓库建立之初（切片 #2）在规则集生效前直接提交到 `main`，因此**首切片无法自证门禁**。这是**唯一**一次豁免，已记录在 Issue #2 的交付评论中。此后所有改动必须经 PR。

（另：`bootstrap.sh` —— 在空仓库一键重建标签/规则集的脚本 —— 尚未实现；标签由 `scripts/sync-labels.sh`、规则集由 `.github/rulesets/main-protection.json` 覆盖，可手工按 §9「规则集分阶段应用」应用。）
