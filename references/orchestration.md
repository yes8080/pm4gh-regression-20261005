# orchestration — 无人工流水线的编排序列（一句目标 → 已合并）

> **何时读**：要把**一句目标**在没有 dispatcher 逐步介入的情况下推到「已合并」（拆片 → 多条切片依次走完 W0..W7）时。
> 单切片的每步**规则正文**在 [flow.md](flow.md)；身份与凭据在 [identity.md](identity.md)；迁移合法性在 [status-machine.md](status-machine.md)。
> **本文件只回答三件事：顺序是什么、每步怎么判成功、失败时做什么** —— 规则正文不复写（复写 = 同一事实两处载体）。
> **入口是文档，不是脚本**：为什么不做 `orchestrate.sh`，见 `SKILL.md`（锚点：`不做编排脚本`）。

## 1. 前置：三身份各自就位（编排者同时持有，但只让脚本用）

| 身份 | 账号 | 凭据 | 谁在什么时候用 |
|---|---|---|---|
| 作者 | `@yes8080-dev-bot` | `$HOME/.config/pm4gh/developer.pat`（scope `repo, workflow`） | 拆片后建 Issue / `scripts/start.sh` / 提交推送 / `scripts/deliver.sh` / `scripts/abort.sh` |
| 评审 | `@yes8080-reviewer-bot` | `$HOME/.config/pm4gh/reviewer.pat`（scope `repo`） | `scripts/review.sh`（**不加** `--as`，脚本自取） |
| 合并 | `@yes8080` | 本机 `gh auth login` 登录态（**没有**凭据文件） | `gh pr merge` / `scripts/closeout.sh` |

- **命令（前置判据）**：

```bash
scripts/preflight.sh
```

- **成功判据**：全 `[ OK ]` 且退出码 `0`；其中必须覆盖：三身份互不相同（第 5、8 组）、作者与评审凭据都在**工作区之外**且权限 `600`（第 5 组）、工作区内没有任何 `*.pat`（第 5、10 组）。
- **失败时做什么**：任一 `[FAIL]` → **如实把原文贴给 dispatcher，禁止继续**（禁止"先干着看"）；缺凭据 / 权限不对 → 按 [identity.md](identity.md) 在**工作区之外**开通，不得为了省事把凭据挪进仓库。
- **边界（不得违反）**：编排者**不得读取评审凭据的内容**（`cat` / `echo` / 打印 / 复制都不行），只让 `scripts/review.sh` 拿它执行；建切片 Issue **不得**用本机 `gh` 登录态（那是 dispatcher 身份 —— 审计归属 = 做事的人）。

## 2. 序列总表（S1..S9；串行，不并发）

| # | 动作 | 命令（形态） | 成功判据（摘要） |
|---|---|---|---|
| S1 | 拆片（编排者自己拆） | 无脚本命令：按 `SKILL.md`（锚点：`切片拆分与分发`）的粒度判据 + DoR 五项 | 每条切片 = 恰好一个可合并改动 |
| S2 | 建 Issue（作者身份） | `gh issue create`（带作者 `GH_TOKEN`） | 打印 Issue URL；状态 = `backlog` |
| S3 | 开工 | `scripts/start.sh <n> --as author` | 退出码 `0`；分支绑定 Issue；`in-progress` |
| S4 | 提交 | `git … commit -F <提交信息文件>`（作者 git 身份） | 工作区干净；署名 = 作者 |
| S5 | 交付 | `scripts/deliver.sh <n> --prepare --as author` → 填六段 → `scripts/deliver.sh <n> --as author` | PR 已建 / 正文回读一致；`in-review` |
| S6 | 必需检查（轮询） | `gh pr checks <pr#> --required` | 5 个 context 在**最新 SHA** 上全 `pass` |
| S7 | 独立评审 | `scripts/review.sh <pr#> approve --body-file <评审意见文件>` | `reviewDecision=APPROVED` |
| S8 | 合并 | `gh pr merge <pr#> --squash --delete-branch` | `MERGED`；关联 Issue 自动关闭 |
| S9 | 收尾 | `scripts/closeout.sh <pr#>` | 五项全过，退出码 `0` |

> **串行，不并发**：同文件不相交区域的两条切片用 `--blocked-by` 串行（blocker 未合并就不开下一条）；**不要并发**两条 —— 工作树是进程级共享，两个 agent 在同一工作区会互相踩（实测，见 §4 卡点 2）。

## 3. 逐步：命令 + 成功判据 + 失败时做什么

### S1 拆片

- **命令**：无（这一步没有脚本，见 §4 卡点 1）。产出是一组切片定义，每条写成一份 Issue 正文文件。
- **成功判据**（三条同时成立才算一条切片，逐字规则见 `SKILL.md`（锚点：`切片拆分与分发`））：① 一个 PR 的六段能写清；② 能独立回滚、不依赖其他**未合并**切片；③ 验收标准逐条可判定。两条切片要改**同一文件的同一区域**、或必须一起合并 → 合成一条；一条切片里出现两个互不依赖的可合并改动 → 拆成两条；同文件但区域不相交 → 保持两条，用 `--blocked-by` 串行。
- **失败时做什么**：**目标本身**有歧义 → 停下问 Issue 作者 / dispatcher（[exceptions.md](exceptions.md) 第 5 条），不许猜；DoR 五项不齐 → 留在 `backlog` 补齐，不得开工；分不出来 → 说明目标句表述不清，回到目标句重写，**禁止**用"一条什么都做的大切片"糊过去。

### S2 以作者身份建 Issue

- **命令**：

```bash
GH_TOKEN="$(cat "$HOME/.config/pm4gh/developer.pat")" \
  gh issue create --title "<标题>" --body-file <正文文件> \
  --label type/task --label role/dev --blocked-by <n>
```

- **成功判据**：退出码 `0` 且打印 Issue URL；随后 `gh issue view <n> --json state,labels` 回读 = `state=OPEN` 且**没有任何 `status/*` 标签**（= 状态 `backlog`）；`--blocked-by` 的边已建立（blocker 的 `state=OPEN` 时本片不可开工）。
- **失败时做什么**：`--label` 传了平台上不存在的标签 → **当场失败**，报 dispatcher（不改标签体系）；被写错身份（用了本机登录态）→ 该单**作废重开**，审计归属不能事后修；`--blocked-by` 指向已关闭的 blocker 却被当成"还阻塞"→ 判定只看 blocker 的 `state`（[traps.md](traps.md) 陷阱 8）；建错要撤 → `scripts/abort.sh <n> --as author`（先加 `--dry-run` 看它要删什么）。
- **非交互约束**：必须 `--body-file` + 显式 `--label`，**禁止** `-T` 表单（非交互下不可用，[traps.md](traps.md) 陷阱 16）。

### S3 开工

- **命令**：

```bash
scripts/start.sh <n> --as author
```

- **成功判据**：退出码 `0`（`1` = 校验或迁移失败 / `2` = 参数错）；分支 `<type>/<issue#>-<slug>` 由 `gh issue develop` 创建并**绑定** Issue；Issue 已指派给作者；状态 = `in-progress`（`gh issue view <n> --json labels` 里 `status/*` **恰好一个**）。
- **失败时做什么**：退出码 `2` → 编号只填数字（`<n>` 不带 `#`）；只读状态预检非法 → 看 [status-machine.md](status-machine.md) 的合法出边（`backlog → in-progress` 合法；`in-review` 要先返修）；**禁止**手工 `git checkout -b`（不建立 Issue 绑定）。线上故障**必须**显式 `--type hotfix`（[traps.md](traps.md) 陷阱 12）。

### S4 提交（作者 git 身份 + `-F`）

- **命令**：

```bash
git add -A && bash -n scripts/*.sh && scripts/status.sh --check
git -c user.name="yes8080-dev-bot" \
    -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" \
    commit -F <提交信息文件>
```

- **成功判据**：`bash -n scripts/*.sh` 与 `scripts/status.sh --check` 退出码均 `0`；`git status --porcelain` 为空（`deliver.sh` 之前工作区必须干净）；`git log -1 --format='%an <%ae>'` = 作者账号（`--as author` 只切 `gh` 的 API 身份，**不改** git 身份）。
- **失败时做什么**：bash 3.2 不兼容（`mapfile` / `declare -A` / `${var,,}` 等，[traps.md](traps.md) 陷阱 7）→ 先修再提交；署名不对 → `git commit --amend` 重做；提交信息里有反引号 / 多行 → 必须走 `-F <文件>`，不要内联进命令行。

### S5 交付 PR

- **命令**：

```bash
scripts/deliver.sh <n> --prepare --as author
# 填六段：Closes #N + ## 1. .. ## 6.（每段非空白字符 >= 20）
scripts/deliver.sh <n> --as author
```

- **成功判据**：退出码 `0`；打印 PR URL 与 `[ OK ] PR 作者：@yes8080-dev-bot`；`gh pr view <pr#> --json body,closingIssuesReferences` 回读到 `Closes #<n>` 且 GitHub **解析出了** `#<n>`；状态 = `in-review`。
- **失败时做什么**：缺 `Closes #N` 或六段 → **在推送之前**失败，补齐正文重跑；当前状态非法 → 脚本在推送之前失败（不写骨架、不推送、不建 PR），先回 S3；返修（分支已有 PR）→ 仍走同一条命令，只推送 + 用 REST 更新正文并回读（**禁止** `gh pr edit` 改正文，[traps.md](traps.md) 陷阱 5）；用 `--prepare --body-file <文件>` 换了路径 → **最终那条命令也要带同一个** `--body-file <文件>`。

### S6 轮询 5 个必需检查

- **命令**（轮询到全 `pass`；CI 有延迟，一次调用不够）：

```bash
for _ in 1 2 3 4 5 6; do
  if gh pr checks <pr#> --required; then break; fi
  sleep 20
done
```

- **成功判据**：`ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template` 这 5 个 context 在**最新 SHA** 上**全部** `pass`（以逐行输出为准；有 `pending` / `fail` 时命令退出码非 `0`）。5 项全 `pass` 才进 S7。
- **失败时做什么**：任一 `fail` → **如实贴原文**，修完在**同一分支**提交再走 S4/S5（新 SHA 上检查重跑）；永久 `pending` → [traps.md](traps.md) 陷阱 1、2（同一 SHA 上"先失败后通过"不可逆；context = job 的 `name:`）；**禁止**用自定义检查 / `/accept` / `--admin` 绕过门禁。

### S7 独立评审（评审身份，**不加** `--as`）

- **命令**：

```bash
scripts/review.sh <pr#> approve --body-file <评审意见文件>
```

- **成功判据**：退出码 `0`；打印 `[ OK ] 评审身份：yes8080-reviewer-bot` 与 `[ OK ] 身份独立（评审 ≠ 作者）`；`gh pr view <pr#> --json reviewDecision` = `APPROVED`（评审**不迁移状态**，停在 `in-review`）。
- **失败时做什么**：认证失败 → 检查评审凭据（工作区之外、权限 `600`）；打成 `request-changes` → 状态回 `in-progress`，在**同一分支**返修后回 S4；返修后的新推送会**驳回旧批准**（`require_last_push_approval`）→ **必须**回本步重评；**禁止自批**（作者批准自己的 PR）。

### S8 合并（只有 dispatcher 能做）

- **命令**：

```bash
gh pr merge <pr#> --squash --delete-branch
```

- **成功判据**：打印 `<old>..<new>  main -> origin/main`；`gh pr view <pr#> --json state,mergedAt` = `MERGED`；关联 Issue 由平台自动关闭（`Closes #N` 生效）。
- **失败时做什么**：缺批准 / 必需检查未过 / 非 `CLEAN` → 合并被拒，回 S6 或 S7；**禁止** `--admin` 或任何绕过门禁的手段；作者不得代跑合并。永久锁死（缺**非作者** code owner 批准）→ 查 [traps.md](traps.md) 陷阱 4。

### S9 收尾

- **命令**：

```bash
scripts/closeout.sh <pr#>
```

- **成功判据**：退出码 `0`，五项全过：① PR 已 `MERGED` ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地头分支已清理**且已留可恢复锚点** ⑤ 无残留 `status/*` 标签。
- **失败时做什么**：任一项不过 → 退出码 `1`，**逐条贴原文**；本地分支删除走 `-D` 而不是 `-d`（squash 后 `-d` 必然拒绝，[traps.md](traps.md) 陷阱 9，脚本已封装）；残留状态标签由脚本自己用 `scripts/status.sh <n> done --as dispatcher` 处理（**仅对已关闭的 Issue**，OPEN 的绝不代关）。

## 4. 必须人判断的点（不许假装全自动）

- **唯一必须由人给的输入 = 目标句本身**。第 2 轮回归 C 轴实测：两次真实合并全程 **0 次人工判断** —— 三身份分离的强制点在**平台**侧（GitHub 拒绝自批 + 规则集 `require_code_owner_review` / `require_last_push_approval`）。
- 仍然要人（或 dispatcher）的三处**边界**，不得宣称已自动化：
  1. **目标有歧义** → 停下问 Issue 作者 / dispatcher（[exceptions.md](exceptions.md) 第 5 条），不许猜。
  2. **合并身份不可自证**：`gh pr merge` 用的是本机登录态，脚本无法证明"现在是不是 dispatcher 环境" → S8 只能在 dispatcher 环境执行。
  3. **拆片粒度**：三条粒度判据可逐条判定，但"两条切片是否改同一文件的同一区域"要编排者**读代码**判断（不是机器判据）。
- 另有**人的纪律**（不是能力缺失）：PR 正文的证据块必须是**本次 SHA** 上的原始输出 —— #161 起由 `<!-- evidence sha=… -->` 做机器断言（标注错误可判，内容真伪不可判）。

## 5. 实测：第 2 轮回归 C 轴（如实记录，不美化）

**目标句**：消灭 #144 测出的两处判据真空。**编排者自拆 2 片**：#151（A 轴里程碑决定）与 #152（B 轴拆分规则，`--blocked-by 151` 串行 —— 两片改同文件的不相交区域）。

| 片 | Issue | PR | 5 个必需检查 | 独立评审 | 合并（squash） | 收尾 |
|---|---|---|---|---|---|---|
| A 轴决定 | #151 | #153 | 全 `pass`（轮询 2 轮） | APPROVED（reviewer-bot） | `8e4b97b` | 五项全过 |
| B 轴规则 | #152 | #154 | 全 `pass`（轮询 2 轮） | APPROVED（reviewer-bot） | `6499c39` | 五项全过 |

原始输出（片段，逐字）：

```bash
$ scripts/deliver.sh 151 --as author
[ OK ] PR 已创建：https://github.com/yes8080/pm4gh/pull/153
[ OK ] PR 作者：@yes8080-dev-bot
[ OK ] GitHub 已解析关闭关系：#151
$ gh pr checks 153 --required
ci/lint pass  ci/test pass  policy/branch-name pass  policy/linked-issue pass  policy/template pass
$ scripts/review.sh 153 approve --body-file /tmp/pm4gh-a144/review153.md
[ OK ] 评审身份：yes8080-reviewer-bot
[ OK ] 身份独立（评审 ≠ 作者）
  reviewDecision=APPROVED  mergeStateStatus=CLEAN
$ gh pr merge 153 --squash --delete-branch
   99713f7..8e4b97b  main -> origin/main
$ scripts/closeout.sh 153
[ OK ] 收尾五项全过：① 已合并 ② Issue 已关 ③ 远端无头分支 ④ 本地无头分支+已留锚点 ⑤ 无残留状态标签
```

（#152 → PR #154 → `8e4b97b..6499c39`，输出同构。）

**卡点（如实）**：

1. **没有编排入口**：`scripts/` 的 7 个脚本里**没有建单入口**（`references/traps.md`（锚点：`本仓库脚本不建 Issue`）明写这一点），S1 / S2 / S6 只能编排者现场手敲 —— 这正是本文件存在的理由；「顺序不进脚本层」的决定见 `SKILL.md`（锚点：`不做编排脚本`）。
2. **同一工作区不能并发两个 agent**：C 轴当时主工作区被另一个 agent 占用（Issue #147），编排者**另开一个独立 clone**（如 `/tmp/pm4gh-c`）才跑通；`preflight` 对「超过一个 `in-progress`」只给 `[WARN]`，而第 3 组又断言「worktree 数量 = 1」→ 并发模型缺口记在 **#159**（未闭合）。
3. **轮询是必需的**：两次都是轮询 2 轮后 5 项全 `pass`（CI 有延迟），不能只跑一次就进 S7。
4. **证据纪律的一次真实违规（不美化）**：PR #154 第 4 节的 `scripts/preflight.sh` 输出块**不是**在该 PR 的 SHA 上跑的，是从 #153 **照搬**的 —— 事后在 `main = 6499c39` 的新 clone 上补验（结论实质成立，但**该 PR 的取证过程不成立**）。此后 PR 正文的每个证据块必须带 `<!-- evidence sha=… -->` 且断言 == 本 PR head SHA（#161）。

## 6. 与 [flow.md](flow.md) 的关系（同源，不产生第二套说法）

- 逐步的**规则正文**（参数取值域、退出码、陷阱）只在 [flow.md](flow.md) / [status-machine.md](status-machine.md) / [traps.md](traps.md)；本文件是它们的**顺序视图 + 每步判据**，不新增规则。
- 本文件里的 `scripts/*.sh` 命令形态由 `ci/test` 的「文档命令可执行性」判据**逐条**喂给脚本的真实参数解析（`--parse-only` 零副作用路径）—— 形态漂移会当场 `[FAIL]`。因此**文档化 = 可执行化 = 可校验化**：不需要 `orchestrate.sh` 来保证文档与脚本一致。
- 顺序变化时：**改本文件**；若那一步属于 W0..W8 的既有步骤，同步 [flow.md](flow.md) 的时序表与 [../SKILL.md](../SKILL.md) 的工作流程。
