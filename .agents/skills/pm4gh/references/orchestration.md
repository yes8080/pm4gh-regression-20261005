# orchestration — 无人工流水线的编排序列（一句目标 → 已合并）

> **何时读**：要把**一句目标**在没有 dispatcher 逐步介入的情况下推到「已合并」（拆片 → 多条切片依次走完 W0..W7）时。
> 单切片的每步**规则正文**在 [flow.md](flow.md)；身份与凭据在 [identity.md](identity.md)；迁移合法性在 [status-machine.md](status-machine.md)。
> **本文件只回答三件事：顺序是什么、每步怎么判成功、失败时做什么** —— 规则正文不复写（复写 = 同一事实两处载体）。
> 下文命令从目标仓库根执行；项目内安装时为脚本路径加 `.agents/skills/pm4gh/` 前缀。
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

- **成功判据**：退出码 `0` 且无 `[FAIL]`（WARN 不阻断，未执行不计入通过）；其中必须覆盖：三身份互不相同（第 5、8 组）、作者与评审凭据都在**工作区之外**且权限 `600`（第 5 组）、工作区内没有任何 `*.pat`（第 5、10 组）、**本 clone 的单写者锁已获取或已接管陈旧锁**（第 3 组；R1）、**当前分支归属一个在途 Issue（`in-progress` 或 `in-review`）**（第 4 组；R2；在基线分支上显式不适用）。
- **失败时做什么**：任一 `[FAIL]` → **如实把原文贴给 dispatcher，禁止继续**（禁止"先干着看"）；缺凭据 / 权限不对 → 按 [identity.md](identity.md) 在**工作区之外**开通，不得为了省事把凭据挪进仓库。
- **边界（不得违反）**：编排者**不得读取评审凭据的内容**（`cat` / `echo` / 打印 / 复制都不行），只让 `scripts/review.sh` 拿它执行；建切片 Issue **不得**用本机 `gh` 登录态（那是 dispatcher 身份 —— 审计归属 = 做事的人）。

## 2. 序列总表（S1..S9；**同一 clone 内**串行）

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

> **同一 clone 内串行**：同文件不相交区域的两条切片用 `--blocked-by` 串行（blocker 未合并就不开下一条）；**同一个 clone 里不要并发**两条 —— 工作树是进程级共享，两个写者在一个 clone 里会互相踩（实测，见 §5 与 §7）。**并行 = 各自独立 clone + 各自 Issue**（模型见 §7）：不要在同一个 git 目录上开多个 worktree（它们共享 Git 元数据，且本流程只支持独立 clone）。

## 3. 逐步：命令 + 成功判据 + 失败时做什么

### S1 拆片

- **命令**：无（这一步没有脚本，见 §4 卡点 1）。产出是一组切片定义，每条写成一份 Issue 正文文件。
- **成功判据**（三条同时成立才算一条切片，逐字规则见 `SKILL.md`（锚点：`切片拆分与分发`））：① 一个 PR 的六段能写清；② 能独立回滚、不依赖其他**未合并**切片；③ 验收标准逐条可判定。两条切片要改**同一文件的同一区域**、或必须一起合并 → 合成一条；一条切片里出现两个互不依赖的可合并改动 → 拆成两条；同文件但区域不相交 → 保持两条，用 `--blocked-by` 串行。
- **失败时做什么**：**目标本身**有歧义 → 停下问 Issue 作者 / dispatcher（[exceptions.md](exceptions.md) 第 5 条），不许猜；DoR 五项不齐 → 留在 `backlog` 补齐，不得开工；目标已是一个可独立验收、合并和回滚的改动 → 保留一条；目标有互不依赖的改动却仍塞入一条 → 继续拆分。不能仅因切片数量是一条就认定目标不清。

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

- **成功判据**：退出码 `0`，五项全过：① PR 已 `MERGED` ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地头分支已清理**且已留可恢复锚点** ⑤ 无残留 `status/*` 标签。五项全过时**同时释放本 clone 的单写者锁**（R4，见 §7；`--dry-run` 不释放）。
- **失败时做什么**：任一项不过 → 退出码 `1`，**逐条贴原文**；分支已由合并工具删除也必须核验每个关联 Issue 的恢复锚点，缺记录则补写并回读；本地 tip 不可得时明确标注，以 PR head 恢复。读取/写入/回读失败不得宣称已留锚点；重复收尾不得重复评论。本地分支删除走 `-D` 而不是 `-d`（squash 后 `-d` 必然拒绝，[traps.md](traps.md) 陷阱 9，脚本已封装）；残留状态标签由脚本自己用 `scripts/status.sh <n> done --as dispatcher` 处理（**仅对已关闭的 Issue**，OPEN 的绝不代关）。

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
2. ~~**同一工作区不能并发两个 agent**~~ **→ 已从「卡点」升级为有模型的规定（#159，见 §7）**：C 轴当时主工作区被另一个 agent 占用（Issue #147），编排者**另开一个独立 clone**（如 `/tmp/pm4gh-c`）才跑通；当时 `preflight` 对「超过一个 `in-progress`」只给 `[WARN]`，而第 3 组又断言「worktree 数量 = 1」→ 并发模型缺口。**#159 的处置**：把「1 clone = 1 写者 = 1 Issue；并行 = 各自独立 clone」写成 §7，并在 `preflight` 第 3/4 组落地 R1（单写者锁）/ R2（分支归属）/ R3（在途数 > 1 仍是 `[WARN]`）；worktree = 1 的断言保留（多个 worktree 共享分支/HEAD 状态，**不是**合法并行形态）。
3. **轮询是必需的**：两次都是轮询 2 轮后 5 项全 `pass`（CI 有延迟），不能只跑一次就进 S7。
4. **证据纪律的一次真实违规（不美化）**：PR #154 第 4 节的 `scripts/preflight.sh` 输出块**不是**在该 PR 的 SHA 上跑的，是从 #153 **照搬**的 —— 事后在 `main = 6499c39` 的新 clone 上补验（结论实质成立，但**该 PR 的取证过程不成立**）。此后 PR 正文的每个证据块必须带 `<!-- evidence sha=… -->` 且断言 == 本 PR head SHA（#161）。

## 6. 与 [flow.md](flow.md) 的关系（同源，不产生第二套说法）

- 逐步的**规则正文**（参数取值域、退出码、陷阱）只在 [flow.md](flow.md) / [status-machine.md](status-machine.md) / [traps.md](traps.md)；本文件是它们的**顺序视图 + 每步判据**，不新增规则。
- 本文件里的 `scripts/*.sh` 命令形态由 `ci/test` 的「文档命令可执行性」判据**逐条**喂给脚本的真实参数解析（`--parse-only` 零副作用路径）—— 形态漂移会当场 `[FAIL]`。因此**文档化 = 可执行化 = 可校验化**：不需要 `orchestrate.sh` 来保证文档与脚本一致。
- 顺序变化时：**改本文件**；若那一步属于 W0..W8 的既有步骤，同步 [flow.md](flow.md) 的时序表与 [../SKILL.md](../SKILL.md) 的工作流程。

## 7. 并发模型（#159 定案：1 clone = 1 写者 = 1 Issue）

**核心命题**：**一个 clone（工作树）= 一个写者 = 一个 Issue**。同一 clone 内**一次只做一个切片**；**并行 = 各自独立 clone + 各自 Issue**（**不是**同一个 git 目录上的多个 worktree —— 那些共享分支/HEAD 状态）。

| 维度 | 规定 | 判据（`scripts/preflight.sh`） |
|---|---|---|
| 同一 clone | 只允许一个写者；一次只做一个切片 | **R1** 单写者锁（第 3 组）+ **R2** 分支归属（第 4 组） |
| 并行 | **允许**，前提 = 各自独立 clone、各自 Issue | **R3**：在途 `in-progress` > 1 是 `[WARN]`（不阻断；它不是「同一 clone 被两个写者占用」的证据） |
| 在途（R2 口径） | 分支所属 Issue = `in-progress`（实现 / 返修）**或** `in-review`（交付后待评审） | **R2**：两者都算「本 clone 的在途项」（#169） |
| 同一 Issue | 一个分支 = 一个 PR；返修在**同一分支** | `policy/branch-name` / `policy/linked-issue`（必需检查） |

### 7.1 R1 单写者锁：位置、内容、生命周期

- **位置（必须在工作区之外）**：`$PM4GH_LOCK_DIR`；默认 `$HOME/.config/pm4gh/locks`（与凭据同目录，见 [identity.md](identity.md)）。默认目录**不可写**时回退到 `/tmp/pm4gh-locks-<uid>`，并在输出里**打印回退原因**（受限环境不因此变成永久假红）；显式指定的 `PM4GH_LOCK_DIR` 不可写 = 配置错（`[FAIL]`，不静默替换）；两个候选都不可写 → `[FAIL]`（fail-closed）。
  - **为什么不能在仓库里**：锁文件会被 `git add`、被「工作区干净」的 `[WARN]` 计数、被凭据/未提交扫描当成未提交改动 —— 判据会污染判据自己。
- **键 = clone 的物理根路径**（`git rev-parse --show-toplevel` 再 `pwd -P`）：锁文件 = `<锁目录>/<clone-id>.lock`。**不按 slug 建锁**：按 slug 会让另一个 clone 的**合法并行写者**被判成「占用」，与「并行 = 各自 clone」直接矛盾。
- **内容**（一行一个 `key=value`）：`pid`（获取锁的进程）/ `branch` / `slug` / `clone` / `time`（epoch 秒）/ `time_iso` / **`cmd`（写者标识 = 活进程实际命令行）** / **`start`（第二判据 = 进程起始时间）**。`PM4GH_LOCK_STALE_MINUTES`（默认 `120`）**只用于接管报文里标注「锁龄偏大」**，**不是**接管的前置条件（#169）。
- **三态显式**（[exceptions.md](exceptions.md) §4）：
  1. **无锁** → 获取并继续（`[ OK ]`）。
  2. **陈旧锁** → **自动接管**并**打印接管原因**（不静默）：`pid` 不存在，**或** `pid` 存活但**写者标识不匹配 / 不可核**（锁里的 `cmd` / `start` 与活进程对不上 = 疑 pid 复用；受限环境里 `ps` 被拒也记空 = 不可核）——#169 起**不再要求**锁龄超阈值（"读不到身份"不等于"是别人的活写者"，拿它判占用正是假红病灶）。锁里的 `branch` / `clone` 与当前不符时另行 `[WARN]` 打印（「本 clone 的分支被切过？」）。
  3. **`pid` 存活且写者标识匹配**（`cmd` 非空且逐字一致，**且** `start` 非空且一致）→ `[FAIL]`：报文含 pid / branch / 时间 / 锁路径，并给出「要并行请另开独立 clone」的修法。
- **生命周期**：W0 `scripts/preflight.sh` **获取 / 接管**；期间每次 W0 重跑都会「接管自己上一次留下的陈旧锁」（锁记的是**进程**，`preflight` 退出即死 ⇒ **不会把自己锁死**）；**正常结束** `scripts/closeout.sh`（五项全过时）与**异常结束** `scripts/abort.sh`（闭环时）**释放本 clone 的锁**（**R4**）。释放只动**本 clone**的锁：`clone` 字段指向别处、或 `pid` 仍存活**且写者标识匹配** → **不删**、只提示（不代他人释放）；`pid` 存活但标识**不匹配 / 不可核** = 复用 → **允许释放**（#169：否则留下陈旧锁）。
- **边界（如实，不得过度宣称）**：① 存活判定用 `kill -0`（bash 内建），对其他用户的进程会因 EPERM 判成「不存在」；身份核对另用 `ps`（受策略限制的环境里会被直接拒绝，此时 `cmd` / `start` 记空 = **不可核** → 按陈旧锁接管，**不**假红）；② 只覆盖**跑 W0 的写者** —— 不跑 `preflight` 就动手的写者不在判据内（这是纪律，不是机制）；③ **不**阻止 `deliver.sh` / `status.sh` 等单步脚本被并发调用（它们不查锁）；④ 若另一个写者把你切到了**它自己的在途** Issue 分支，**R2 不报**（该分支确实合规）—— 那种形态只有在双方都跑 W0 时由 R1 兜住；⑤ 判据在**全部合法流程状态**下必须不假红（清单与证据要求见 [exceptions.md](exceptions.md) §7）。

### 7.2 R2 分支归属 与 R3 在途数

- **R2**：当前分支若是切片分支形态 `<type>/<issue#>-<slug>`（`type ∈ {slice,fix,hotfix,spike,chore}`），其 Issue 必须 **OPEN 且在途** = 带 `status/in-progress` **或** `status/in-review`（#169：**交付后待评审**是合法运行点 —— `deliver.sh` 交付后 Issue 变 `in-review` 而作者仍在分支上等评审）；OPEN 但只有 `status/ready` / 无 `status/*`（backlog）、已 CLOSED（done / canceled）、读不到该 Issue → `[FAIL]`（fail-closed）。**基线分支上显式不适用**（W0 允许在开工前跑，开工后 `scripts/start.sh` 必然切到切片分支）—— 打印 `[WARN]` 说明「本判据**未执行**」，不计入通过；游离 HEAD / 非切片分支形态 = `[FAIL]`（无法证明归属，fail-closed）。**六态清单**（开工前 / 实现中 / 交付后待评审 / 返修中 / 终止后 / 被切走）与「另一侧」证据要求见 [exceptions.md](exceptions.md) §7。
- **R3**：在途 `in-progress` > 1 **仍是 `[WARN]`**，**不升为 `[FAIL]`**。理由：在途数**不是**「同一 clone 被两个写者占用」的证据 —— 两个 `in-progress` 可能落在两个独立 clone 上（正是本模型允许的并行形态）；升为 FAIL 既禁止了合法并行，又把判据压在**错误的观测量**上。同一 clone 的互踩由 R1/R2 判定。`scripts/status.sh --check` 的小结打印**同一说法**。
