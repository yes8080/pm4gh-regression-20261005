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
scripts/toolcheck.sh          # 10 项自检：命令/gh 登录/规则集漂移/必需检查/凭据/git 远端/git 工作区预检
```

**任何一项未通过都不要开始干活。** 最常见的两类失败：

| 现象 | 原因 | 处理 |
|---|---|---|
| 凭据文件不存在或权限不是 600 | 没有 `.secrets/reviewer.pat` | 见 §3 |
| 线上规则集与仓库定义不一致 | 有人手动改过规则集 | `scripts/audit.sh` 查看差异；按 §9 规则集流程修正 |

---

## 3. 凭据（身份与权限）

本项目用**三个身份**模拟真实团队的作者/评审分离（决策 D1 + D2）：

| 身份 | 用途 | 凭据形式 | 存放 |
|---|---|---|---|
| dispatcher / 主身份 `yes8080` | 治理、规则集、合并、发布 | 本机 `gh auth login` | 系统钥匙串 |
| 作者身份 `yes8080-dev-bot` | 建分支、提交、开 PR、返修（`--as author`） | **classic PAT，`repo` + `workflow`** | `.secrets/developer.pat`（0600，已 gitignore） |
| 评审/验收身份 `yes8080-reviewer-bot` | 独立评审、`/accept` 记录 | **classic PAT，只勾 `repo`** | `.secrets/reviewer.pat`（0600，已 gitignore） |

> **D9 后已不再需要 `project` scope 的凭据**：Projects 已移除，主身份只用 `gh` 登录即可。
> 若你此前签发过带 `project` 的 token（`.secrets/main.pat`），**建议立即在 GitHub 上撤销**（本仓库已删除该文件）。
> 作者身份为什么必须含 `workflow`：见 W0.4（Bug #51 原文与 PM 裁定）。

**为什么必须是 classic 而不是 fine-grained**（官方限制，见 附录 C.3）：
fine-grained PAT **无法**用于"用户作为 repository collaborator 的仓库"，也**无法**访问"用户账号拥有的 Projects"—— 本项目两条都踩中。

**使用方式**（脚本已封装，手工操作时照此）：
`scripts/start.sh` / `scripts/deliver.sh` 的 `--as author|main` 会自动完成下面的切换与自检，**不要**再用 `GITHUB_TOKEN=` 迂回（Bug #53）。

```bash
# 主身份（dispatcher）：不要设置 GH_TOKEN / GITHUB_TOKEN
unset GH_TOKEN GITHUB_TOKEN

# 作者身份（建分支/提交/开 PR）
export GH_TOKEN="$(cat .secrets/developer.pat)"
gh api user --jq .login        # 应输出 yes8080-dev-bot
unset GH_TOKEN                 # 用完立刻切回主身份

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
| **绕过 `start.sh` 直接建分支会被门禁拒绝** | 用 `gh issue develop` 手工建分支**跳过了状态迁移**：Issue 仍在 `Backlog`（无 `status/*` 标签）→ `policy/branch-name` 判定「从 Backlog 直接开 PR」并失败。**而且改标签不会重跑 `pull_request` 事件**，失败的必需检查会永久留在该 SHA 上（Bug #13 同型） | 一律走 `scripts/start.sh <issue#>`（它内部建分支并迁状态）；若已手工建分支，先执行 `scripts/status.sh <issue#> in-progress`，**再推一个新提交产生新 SHA** 触发重跑 |
| **同一 workspace 只允许一个执行者** | 两个执行者并发会互相删分支/切 HEAD（本项目已实际发生：演练执行者的分支被我清理时被切走，它靠悬空 commit 恢复） | 交接必须显式"让出"：确认对方工作区干净且已切回 `main` 后再动手。**默认串行**：`/Users/ws/code/AGENTS.md` 明令禁止 `clone` / `worktree` / 隔离实现副本（走重复依赖与配置漂移），因此**不允许靠开副本并行**；`scripts/toolcheck.sh` 会检测 worktree 数量并拒绝继续 |
| **环境里残留失效的 `GH_TOKEN` 会让所有脚本在 source 阶段就失败** | `lib.sh` 在 **source 时**（早于 `use_main_identity`）就用 `gh repo view` 解析 `REPO`，失效 token → 报"无法确定仓库" | 要强制主身份的脚本需在 `source lib.sh` **之前** `unset GH_TOKEN`（`scripts/report.sh` 已如此处理）；排查时先 `unset GH_TOKEN` |
| **`GITHUB_TOKEN` 会悄悄顶掉"主身份"** | `gh` 的凭据回退链是 `GH_TOKEN` → `GITHUB_TOKEN` → 登录态。早期 `use_main_identity` 只清 `GH_TOKEN`，于是 `GITHUB_TOKEN=<作者 PAT> scripts/xxx.sh`（Bug #53 的临时绕过）会以**作者身份**跑"主身份脚本" | 两个 `use_*_identity` 现在都显式清理这两个变量；`--as main|author` 是**唯一**的文档化选择方式，不要再用环境变量迂回（Bug #53/#54） |
| **作者身份推送 `.github/workflows/**` 需要 `workflow` scope** | 只有一个 `repo` 的 classic PAT 会让**整个 push** 被服务端拒绝：`refusing to allow a Personal Access Token to create or update workflow … without 'workflow' scope`（Bug #51，作者身份的 `--as author` 会告警，`scripts/toolcheck.sh` 第 10 项会直接失败） | 按 W0.4 重新签发作者 classic PAT：`repo` + `workflow`；**不要**改用主身份推、**不要** `--admin` |
| **把命令输出接给 `tail` 会吞掉失败退出码** | 未开 `pipefail` 时管道退出码取自最后一个命令：旧版 `deliver.sh` 的 `git push … 2>&1` 接 `tail -2`，推送被服务端拒绝后仍继续执行，可能用**远端的旧分支**建出一个 PR | 需要"既看输出又判失败"时先赋值再判：`if ! out="$(cmd 2>&1)"; then …; fi`（`scripts/deliver.sh` 已如此处理） |
| **作者身份（`repo` + `workflow`）用不了 `gh pr edit`** | `gh pr edit` 走 **GraphQL**，其查询取 `login` / `name` / `slug` 等字段、需要 `read:org`；作者 PAT 只有 `repo` + `workflow` → `GraphQL: Your token has not been granted the required scopes … 'read:org'`，**正文不会被更新**（#54 实测） | PM 裁定（#54）：**不给作者扩权**（`read:org` 与 D1 最小权限冲突），改为用 `scripts/lib.sh` 的 `pr_edit_body <pr#> <正文文件>`（REST `PATCH /repos/{o}/{r}/pulls/{n}` + 回读校验，失败直接暴露；随 #47 交付）。`gh pr create` / `gh pr comment` / `gh pr view` 走 REST，不受影响 |
| **`printf '%s'` 不带换行 → 循环里逐行输出被拼成一行** | `render_str`（本套件占位符渲染）用 `printf '%s'`，把 `render_str … \| sed …` 放进 `while` 循环直接输出时，多个结果会**首尾相连成一行**，下游 `grep -Fxq` 全部失配（S2 实测：`eject --check` 误报"CODEOWNERS 原有行被动了"，`wc -l` 为 0） | 循环里逐行输出必须自己补换行：`printf '%s\n' "$(render_str … \| sed …)"`。**注意**：这个脚本在 `set -eu` 下不会报错，只会静默给出错误数据 —— 复核判据脚本时优先看"输出行数对不对" |
| **改 `.github/workflows/**` 忘了同步 `toolkit/payload/workflows/**`** | 只改前者时本仓库门禁变紧，但**装到目标仓库的 CI 静默缺这一步**（两处差异应**只有占位符** `@@OWNER@@` 等）；这是"门禁看起来在、实际没装"的形态 | 改任一处必须同步另一处，并用 `diff .github/workflows/X.yml toolkit/payload/workflows/X.yml` 核对：**除占位符外无差异**。`toolkit/tests/self-test.sh` 会真跑安装流程，步骤缺失即 CI 变红 |
| **反向样本"故意让门禁变红"怕违反 §7 规则 1** | 规则 1 禁止的是**同一个 commit SHA** 上"先失败后通过"（Bug #13）：那样该 SHA 的必需检查永远无法转绿 | 反向样本可以这样做：在切片分支推一个**故意失败**的临时提交 → 抓取 `ci/test` 的红色日志 → **再推一个新提交**修复。PR 的可合并性只看**头 SHA** 的检查，新 SHA 会得到全新的检查结论（实测 #57：`ci/test` 在临时 SHA 上 `FAIL=1` 变红，修复后头 SHA 全绿）。squash 合并后这些临时提交不会进入 `main` 历史 |

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

### W0.4 身份开通：为每个角色开通一个账号（**可复用到任意项目**）

> **官方硬限制**：**PAT 只能在浏览器创建 —— GitHub 没有创建 PAT 的 API**（classic 与 fine-grained 都没有）。
> 因此第 1 步必须人工完成一次，其余步骤可脚本化。

**角色 ↔ 账号 ↔ 凭据对照**

| 角色 | 账号 | 凭据 | scope（classic PAT）与权限 |
|---|---|---|---|
| dispatcher（**唯一合并者** + 仓库/规则集管理） | `yes8080` | `gh` 登录态 | `repo` + `workflow`（登录态）；仓库 admin |
| 作者（建分支 / 提交 / 开 PR / 返修） | `yes8080-dev-bot` | `.secrets/developer.pat` | **`repo` + `workflow`**；write（**禁合并**） |
| 评审 + 验收（approve、`/accept`） | `yes8080-reviewer-bot` | `.secrets/reviewer.pat` | 只勾 `repo`；write（**禁合并、禁改码**） |

**为什么必须是 classic PAT（官方依据）**
- **细粒度 PAT 不可用**：官方明确列为未支持缺口 —— "contribute to **repositories where the user is an outside or repository collaborator**"。我们的 bot 恰是协作者。
- **GitHub App 不可用于评审**：CODEOWNERS 只接受"具有显式 `write` 权限的**用户名或团队名**"，App 不是协作者、不能成为 code owner → 会让 `require_code_owner_review` **永久无法满足**（Bug #13 同型死锁）。
- 结论：**评审身份必须是"用户账号 + classic PAT"**。

**为什么作者身份必须多勾一个 `workflow`（Bug #51 实测，2026-10-04 更正）**

原文（旧版 W0.4）写的是"Scope **只勾 `repo`**"，**这是错的**。`repo` 单独不足以创建/更新
`.github/workflows/**`：推送会被服务端**整体拒绝**（整个 push 失败，不是只跳过那个文件），原文：

```text
! [remote rejected] <branch> -> <branch>
(refusing to allow a Personal Access Token to create or update workflow
 `.github/workflows/required-checks.yml` without `workflow` scope)
```

判据与影响面：去掉该文件改动后**完全相同的推送命令**立即成功（`1b67b18..5dd89ec`），
说明失败原因确定是 PAT scope，而不是网络/权限/分支保护（证据见 Bug #51）。
`.github/workflows/**` 正是本套件"往目标仓库装策略"的核心目录（S4 的四项策略就是 workflow 文件），
若只有 dispatcher 能推，等于把写权限重新集中回单一账号，与决策 D1 的身份分离目标相矛盾 ——
因此 PM 裁定（#51）：**给作者身份补 `workflow` scope**，而不是"workflow 改动只能由 dispatcher 推"。
`scripts/toolcheck.sh` 第 10 项会硬校验作者 scope（缺 `workflow` 直接失败，不会静默跳过）。

**开通流程（对每个角色重复）**

1. **创建 token（人工，唯一的人工步骤）**
   - **必须先用目标账号登录浏览器**（建议无痕窗口）。登错账号会生成属于别人的 token —— 本项目实测踩过。
   - https://github.com/settings/tokens → `Generate new token (classic)`
   - Note：`<repo>-<role>`（如 `pm4gh-dev`）；Expiration：建议 90 天
   - **Scope：作者 = `repo` + `workflow`；评审 = 只勾 `repo`**（作者的 `workflow` 不可省，见上一节原文）
2. **保存进项目**（绝不进版本库）
   ```bash
   printf '%s' '<token>' > .secrets/developer.pat
   chmod 600 .secrets/developer.pat
   git check-ignore .secrets/developer.pat      # 必须输出路径 = 已被忽略
   ```
3. **核对身份**（发错账号会在此暴露）
   ```bash
   curl -sS -H "Authorization: token $(cat .secrets/developer.pat)" \
     https://api.github.com/user | jq -r .login     # 必须等于该角色预期账号
   ```
4. **邀请为协作者**（仓库 owner 执行；`push` = write）
   ```bash
   gh api -X PUT repos/<owner>/<repo>/collaborators/<account> -f permission=push
   ```
5. **由该账号接受邀请**（不接受的邀请不产生任何权限）
   ```bash
   TOK="$(cat .secrets/developer.pat)"
   INV="$(curl -sS -H "Authorization: token $TOK" https://api.github.com/user/repository_invitations \
         | jq -r '.[] | select(.repository.full_name=="<owner>/<repo>") | .id' | head -1)"
   curl -sS -X PATCH -H "Authorization: token $TOK" \
     "https://api.github.com/user/repository_invitations/$INV"    # 204 = 成功
   ```
6. **等初始化并回读验证**（权限生效不是瞬时的，**必须**回读确认而不是假定成功）
   ```bash
   scripts/toolcheck.sh      # 第 10 项校验两个 bot 身份、权限**与 scope**
   ```
   期望：`push=true`、`admin=false`、读 Issue 返回 200；**作者凭据 scope 含 `repo` + `workflow`**（缺 `workflow` 该项直接失败）。

> **典型症状**：身份与 scope 都正确、却访问仓库 **404** —— 说明第 4/5 步没做（私有仓库对无权限者隐藏存在性）。
> **登记要求**：新增协作者属**持久权限**，必须在套件 `manifest.json` 中登记；卸载时**询问式**处理（默认保留并报告，`--force` 才撤销）。

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
scripts/start.sh <issue#> --as author          # 推荐：决策 D1 —— 建分支/指派/开工评论都记在作者名下
# 若确实要以 dispatcher 身份开工（默认值，向后兼容）：
scripts/start.sh <issue#> --as main
# 等价手工命令（执行身份由 GH_TOKEN 决定，见 §3）：
gh issue develop <issue#> --base main --name slice/<issue#>-<slug> --checkout
gh issue edit <issue#> --add-assignee @me
scripts/status.sh <issue#> in-progress      # 状态迁移（start.sh 已自动执行）
```
**必须用 `gh issue develop`**：手工 `git checkout -b` 不会建立 Issue ↔ 分支绑定，Issue 的 Development 区块不显示分支。

`--as author|main`（Bug #53 PM 裁定）：
- **默认 `main`**（`gh` 登录的 dispatcher 身份），保持向后兼容；`author` 用 `.secrets/developer.pat`。
- `--as author` 会调用 `use_developer_identity()` 并做**两道自检**：① 当前生效身份 == 凭据里的作者身份；
  ② **身份分离**（作者 ≠ 评审、作者 ≠ `gh` 登录的主身份）。任一不满足即失败退出 ——
  这样 Issue 指派、开工评论、分支、提交、PR 的作者全部是 `yes8080-dev-bot`（D1），
  也堵住"token 放错文件 / 登错浏览器账号导致作者身份静默变成主身份"的坑（W0.4 实测踩过）。
- **状态标签迁移仍由 `status.sh` 以主身份执行**：状态机是共享记账动作，不属于"作者身份上链"的四处。
- 早期为了以作者身份开工，只能用**未文档化**的 `GITHUB_TOKEN="$(cat .secrets/developer.pat)"` 迂回；
  现在 `--as author` 是唯一文档化入口，`GITHUB_TOKEN` 迂回**不再需要也不可靠**（`use_main_identity` 会清掉它）。

### W4 开发与提交
```bash
# Conventional Commits + Issue 号；**提交信息用 -F 传文件**（带反引号/多行的信息不要内联到命令行）
printf '%s\n' "feat(scope): 说明 (#123)" > /tmp/msg.txt
git -c user.name="yes8080-dev-bot" \
    -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" \
    commit -F /tmp/msg.txt

bash -n scripts/*.sh                        # 若改了脚本（CI 的 ci/lint 现在覆盖全部被跟踪的 *.sh）
bash toolkit/tests/self-test.sh             # 若改了 toolkit/
```
**为什么提交要显式 `-c`**：`--as author` 只切换 `gh` 的 API 身份（`GH_TOKEN`），**不会**改 git 的 `user.name/user.email`。
不显式指定时，提交会记在本地全局 git 配置（通常是主身份）名下 → 四处身份不一致（D1 落空）。
两个值可直接复制 `scripts/start.sh <issue#> --as author` 结尾打印的那一行。

### W5 交付 PR
```bash
scripts/deliver.sh <issue#> --prepare --as author   # 生成六段正文骨架到 .git/PR_BODY_<n>.md
# 填写骨架（六段都要有实质内容；关联 Bug 时写 Fixes #NNN）
scripts/deliver.sh <issue#> --as author             # 推送分支 + 创建 PR（作者身份）
```
判定：正文含 `Closes #<issue#>`；六段齐备；工作区干净；分支名合规。
`deliver.sh` 会自动把状态迁到 `in-review`，并回显 `PR 作者：@<身份>`（与本次 `--as` 对照即可发现身份串位）。
推送失败时脚本会**带服务端原文失败退出**（不再被 `tail` 吞掉）；若原文是 `without 'workflow' scope`，按 W0.4 重签凭据，
**不要**改用主身份推、**不要** `--admin`。

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
5. 返修时若要改 **PR 正文**：不要用 `gh pr edit`（作者凭据缺 `read:org`，见 §4 环境陷阱），
   用 `scripts/lib.sh` 的 `pr_edit_body <pr#> <正文文件>`（REST 实现 + 回读校验 + 失败暴露）。

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
| 签发/轮换 PAT | 需在目标账号的浏览器会话中操作 | classic token；**作者（`yes8080-dev-bot`）勾 `repo` + `workflow`**；评审（`yes8080-reviewer-bot`）勾 `repo`；主身份（`yes8080`）用 `gh auth login`（D9 后不再需要 `project`）。写入 `.secrets/<name>.pat` 后 `chmod 600`，并跑 `scripts/toolcheck.sh` 第 10 项核对身份/权限/scope |
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
