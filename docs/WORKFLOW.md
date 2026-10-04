# WORKFLOW — 多 agent + GitHub 开发工作流

> [README](../README.md) 讲本质，[AGENTS.md](../AGENTS.md) 讲契约，本文件讲**步骤与判据**；冲突时 **GitHub 平台实际行为 > 本文件 > AGENTS.md**。发现冲突开 Issue 改文档，而不是按"更方便"执行。

## 0. 三身份（**唯一权威**：README / AGENTS 只链接本表，不复述）

| 角色 | 账号 | 凭据 | 职责 |
|---|---|---|---|
| 作者 | `@yes8080-dev-bot` | **`$HOME/.config/pm4gh/developer.pat`**（`repo, workflow`）—— **必须在工作区之外** | 建分支、提交、推送、开 PR、返修（`--as author`） |
| 评审 | `@yes8080-reviewer-bot` | **`$HOME/.config/pm4gh/reviewer.pat`**（`repo`）—— **必须在工作区之外** | `approve` / `request-changes`（不得合并；**不加** `--as`） |
| 合并 | `@yes8080` | 本机 `gh auth login` 登录态 | 合并、改仓库设置、跑 `closeout.sh` |

身份由**平台**强制（GitHub 禁止自我批准）：作者凭据缺 `workflow` scope → 推送 `.github/workflows/**` 被服务端整体拒绝；评审凭据失效 → `.github/**`、`scripts/**`、`docs/**` 永久无法合并（`require_code_owner_review`）。作者凭据的 scope/最小权限、以及**评审凭据在不在工作区之外**由 `preflight.sh`（W0）断言；评审凭据**自身**的认证与写权限由 W6 `review.sh` 自检（`preflight.sh` 不读其他身份的凭据内容 —— 口径见 [AGENTS.md §5.1](../AGENTS.md)）。**`--as` 只接受 `author`**（未知值报错）—— 没有任何脚本能把作者"切换"成 dispatcher。

### W0 身份开通：凭据放哪（**机器判据，不是口号**）

评审凭据**必须在工作区之外**（`#94`）：作者 agent 与你在同一工作区里运行 —— 工作区内的评审凭据 = 作者可读，「独立评审」只剩名义。作者凭据同理（`#94` PM 裁定 (B)：默认路径指向工作区内已不存在的位置 = 把配置漂移写进默认值，默认值必须可用）。

```bash
mkdir -p "$HOME/.config/pm4gh" && chmod 700 "$HOME/.config/pm4gh"   # 两个身份凭据的存放目录（工作区外）
mv .secrets/developer.pat "$HOME/.config/pm4gh/developer.pat"      # 作者凭据，若它还在工作区里
mv .secrets/reviewer.pat "$HOME/.config/pm4gh/reviewer.pat"        # 评审凭据，若它还在工作区里
chmod 600 "$HOME/.config/pm4gh/developer.pat" "$HOME/.config/pm4gh/reviewer.pat"
```

判据：`scripts/review.sh`（默认 `REVIEWER_PAT_FILE=$HOME/.config/pm4gh/reviewer.pat`）与 `scripts/preflight.sh`（作者侧默认 `DEVELOPER_PAT_FILE=$HOME/.config/pm4gh/developer.pat`）都把给定路径解析成**绝对路径**（`cd … && pwd -P`）；落在**仓库根之内** → `review.sh` 报错退出、`preflight.sh` 记 `[FAIL] 隔离缺口`，两者都打印上面这几条确切命令；`preflight.sh` 另断言**工作区内不得存在任何凭据文件**（`.secrets/` 下残留 `*.pat` → `[FAIL]`）。换别的工作区外路径：`REVIEWER_PAT_FILE=/工作区外/路径 scripts/review.sh <pr#> approve --body-file <文件>`。行为允许/禁止的口径只在 [AGENTS.md §5.1](../AGENTS.md) 写一次，本文件不复述；**隔离的强度边界见 §4 陷阱 13**。

## 1. 状态机（唯一源）

> 状态 = `status/*` 标签 + Issue 开关；**没有本地状态文件**。迁移只能走 `scripts/status.sh <issue#> <state>`，且**判据是「HTTP 层单请求」**（标签改动只有一条 REST `PUT …/labels` 整份替换 —— 不是「一次 `gh issue edit`」；见 §4 陷阱 10）。
> 状态集 **6 个**：`backlog | ready | in-progress | in-review | done | canceled`；`in-review` = 「评审中 / 已批准待合并」（没有单独的「验收」状态，批准本身就是验收门禁）。「被打回」**不设独立状态** —— 平台已免费提供 `reviewDecision=CHANGES_REQUESTED`，打回 = `in-review → in-progress`。

### 状态迁移表（**唯一表权威**：6 个状态、14 条边；与 `scripts/status.sh` 的 `TRANSITIONS` 由 `ci/test` 断言**逐字一致**）

> 这里**没有图**（Issue #107）：AI 读的是 token 不是像素 —— 表一行一条边、可 grep/awk 校验；图带语法开销、隐式节点易漏，还要额外断言才不漂移。
> `类型` 取值：`正常` = 主路径推进；`异常` = 回退 / 打回 / 终止；`终态` = 进入 `done`（合并关单）或终态本身（无出边）。

<!-- TRANSITIONS:BEGIN（机器可读；与 scripts/status.sh 的 TRANSITIONS 逐字一致，由 ci/test 断言；首列 = 状态集，其余反引号 token = 出边） -->

| from | to | 触发者 | 命令/事件 | 类型 |
|---|---|---|---|---|
`backlog` | `ready` | 人/PM | W1 DoR 五项齐备 | 正常
`backlog` | `in-progress` | dev-bot | W2 start.sh 直接开工（不假定 Issue 在 backlog） | 正常
`backlog` | `canceled` | 人/PM | 不做（dispatcher 确认） | 异常
`ready` | `in-progress` | dev-bot | W2 start.sh 开工 | 正常
`ready` | `backlog` | 人/PM | 收回（DoR 不再齐备） | 异常
`ready` | `canceled` | 人/PM | 不做（dispatcher 确认） | 异常
`in-progress` | `in-review` | dev-bot | W4 deliver.sh 推送并开 PR | 正常
`in-progress` | `ready` | 人/PM | 退回补 DoR | 异常
`in-progress` | `backlog` | 人/PM | 重置 | 异常
`in-progress` | `canceled` | 人/PM | 不做（W8 abort.sh 清分支） | 异常
`in-review` | `in-progress` | reviewer-bot | W6 评审 request-changes（平台 reviewDecision=CHANGES_REQUESTED；同分支返修） | 异常
`in-review` | `done` | dispatcher | W7 合并关单 + closeout.sh | 终态
`in-review` | `backlog` | 人/PM | 重置 | 异常
`in-review` | `canceled` | 人/PM | 不做 | 异常
`done` | （终态；无出边） | — | 只能 gh issue reopen 后走合法边 | 终态
`canceled` | （终态；无出边） | — | 只能 gh issue reopen 后走合法边 | 终态

<!-- TRANSITIONS:END -->

`done` / `canceled` 无出边。**转换表是强制的**：表外 `from → to` → `status.sh` 失败（退出码 1），**没有跳过开关** ——
需要例外就开 Issue 补一条边（同时改 `status.sh` 的 `TRANSITIONS` 与本表，两处由 `ci/test` 断言**逐字一致**）。

### 状态载体与体检

载体：`ready`/`in-progress`/`in-review` = 对应 `status/*` 标签（**互斥**）；`backlog` = Issue OPEN 且无 `status/*`；`done`/`canceled` = Issue `CLOSED`（`state_reason=completed` / `not planned`）**且**无任何 `status/*` 标签。
体检：`scripts/status.sh --check` 扫全部开放 Issue，每个必须 0 或 1 个 `status/*`（0 = backlog）；`ci/test` 每次 PR 跑同一不变量。

**只读预检（副作用之前）**：`scripts/status.sh --check-transition <from> <to>` **零副作用**（不读网络/凭据、不写任何东西；退出码 0 合法 / 1 非法 / 2 用法错），非法时打印该 `from` 的合法出边与正确命令。
`start.sh`（建分支前）与 `deliver.sh`（推送/建 PR 前）**先读平台当前状态、再调用它**：非法立即失败，不留半成品（`start.sh` 不假定 Issue 在 `backlog`）。

### 交叉体检（只读，Issue ↔ PR）— `scripts/status.sh --check-cross`

`--check`、`ci/test`、`policy/*` **都只读 Issue**，所以「Issue 已 in-review 而关联 PR 被关闭」这类不一致曾经没有任何门禁能看到。本命令同时读 Issue 与 PR、**零副作用**（只发 GET、只写临时目录）：

| 规则 | 判据 |
|---|---|
| R1 | Issue 为 `in-review`，但关联 PR 已 `CLOSED`（未合并） |
| R2 | Issue 为 `done`，但关联 PR 未合并（仍开放 / 已关闭未合并） |
| R3 | Issue 为 `in-review`，但**没有任何开放 PR** |
| R4 | 有开放 PR，但 Issue 无任何 `status/*`（Backlog） |

「关联」只认两种**可判定**证据：PR 的 `closingIssuesReferences`（GitHub 解析出的关闭关系）或分支名 `<type>/<issue#>-<slug>`；两者都没有的 PR **不得猜测** —— 如实标注「无法判定」并列出，不计入冲突。退出码 0 = 四条全未命中；1 = 存在冲突（逐条打印规则、Issue/PR 号与关联方式）。

### 标签族定位（**唯一一处**声明；别处只引用本表，不复述）

标签是**仓库级对象**，不在版本库里，只能靠断言防漂移：机器消费的标签由 `preflight.sh`（W0）与 `ci/test`（每次 PR）用**同一段判据**（`LABEL_ASSERT`，`ci/test` 断言两处逐字一致，并带反向样本）断言存在。

| 标签族 | 定位 |
|---|---|
| `status/*` | **消费者**：`status.sh`（唯一迁移入口）/`start.sh`/`deliver.sh`/`abort.sh`/`closeout.sh`/`ci/test`；标签缺失会让 `status.sh` 的迁移**直接失败** |
| `type/*` | **消费者**（仅 `bug`/`hotfix`/`spike`/`chore`）：`start.sh` 据此推导分支类型；`task`/`feature` 无消费者 → 人类元数据 |
| `prio/*`、`risk/*`、`role/*`、`area/*`、GitHub 默认标签（`bug`/`documentation`/`duplicate`/`enhancement`/`good first issue`/`help wanted`/`invalid`/`question`/`wontfix`/`accessibility`） | **人类元数据（机器不读）**：优先级/风险提示/角色与模块导航；仓库内零引用，只供人筛选 |
| `src/*`、`size/*` | **删除**（v1 遗留 / 与 `slice.yml` ⑤ 的 Size 正文重复：Issue 表单**不能**自动打标签 → 标签这一载体必然与正文漂移）；线上删除由 dispatcher 执行（见 Issue #103） |

## 2. W0..W8 闭环

### 时序步骤表（谁在什么时候触发；取代原时序图 —— Issue #107）

| # | 角色 | 动作 | 产物/门禁 | 失败·返修 |
|---|---|---|---|---|
| 1 | 人/PM | 交 Issue + 验收标准（DoR 五项） | Issue（W1）；此前**状态 `backlog`**（OPEN 且无 `status/*`） | DoR 不齐 → 留在 `backlog` 补齐 |
| 2 | dev-bot | W2 `start.sh <issue#> --as author`：建分支 + 绑定 Issue + 指派给作者 | 分支 `<type>/<issue#>-<slug>`；**状态 `in-progress`**（W0 预检全过） | 只读状态预检非法 → **建分支之前**失败 |
| 3 | dev-bot | W3 实现 + 提交（作者身份，`commit -F`） | 提交；工作区干净；`bash -n scripts/*.sh` 通过 | 语法 / bash 3.2 兼容性失败 → 先修 |
| 4 | dev-bot | W4 `deliver.sh <issue#> --as author`：推送并开 PR / 更新正文 | PR 正文含 `Closes #N` + 六段；**状态 `in-review`** | 缺 `Closes #N` / 六段 → 推送前失败 |
| 5 | CI/规则集 | W5 跑 5 项必需检查（PR 事件触发） | `ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template` 全 `pass` | 任一失败 → 修后同分支再推（走 #7） |
| 6 | reviewer-bot | W6 独立评审（评审凭据，**不加** `--as`；禁止自批） | `reviewDecision=APPROVED` → 停在 `in-review`（已批准待合并） | `request-changes` → **状态 `in-progress`**（平台 `reviewDecision=CHANGES_REQUESTED`）；旧批准留在原 SHA |
| 7 | dev-bot | 返修：**同一分支**继续提交（不新建分支/PR）后 `deliver.sh` 再推 | 新 SHA；必需检查在新 SHA **重跑**；**状态 `in-progress → in-review`** | `require_last_push_approval` **驳回旧批准** → 必须回 #6 重评 |
| 8 | dispatcher | W7 `gh pr merge <pr#> --squash --delete-branch`（只有 `@yes8080` 能做） | Issue 自动关单 → **状态 `done`** | 缺批准 / 必需检查未过 → 合并被拒 |
| 9 | dispatcher | `closeout.sh <pr#>` 五项核验 | ① PR MERGED ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地无头分支已清理 ⑤ 无残留 `status/*` 标签 | 任一项不过 → 贴原文报告；⑤ 由脚本自己 `status.sh <n> done` |

> 顺序之外只有 W8：异常路径出口（PR 关闭不合并 / 作者放弃 / Issue 已取消）→ `scripts/abort.sh <issue#>` → `canceled`（见 W8）。

### W0 预检（每次接手都跑）— `scripts/preflight.sh`

全部 `[ OK ]` 才继续；任何 `[FAIL]` → 把原文报告 dispatcher，**不要"先干着看"**。它检查：命令齐备 / gh 登录 / cwd 在仓库内且非 worktree / 工作区状态 / 远端唯一 origin / 作者凭据可用（认证、`workflow` scope、最小权限）且 ≠ gh 登录身份 / 评审凭据在**工作区之外**（只做内容无关判据；缺失记 `[WARN]`，属 W6 的前置）/ 凭据未入库且权限 600 / 线上规则集与 `.github/rulesets/main-protection.json` 的必需 context 一致 / 每个必需 context 都有工作流 job。

### W1 领片（DoR）— `gh issue list --state open --label status/ready --limit 20 --json number,title,labels`

五项全齐才可从 backlog → `ready`：① 价值一句话 ② 可判定的验收标准 ③ 明确不改什么（边界）④ 依赖与契约 ⑤ 规模与执行者。

### W2 开工 — `scripts/start.sh <issue#> --as author`

**先做只读状态预检**（读平台当前状态 → `status.sh --check-transition <cur> in-progress`）：非法（例如 Issue 停在 `in-review`）→ **在创建分支之前**失败，绝不留下半成品。然后：校验 Issue OPEN 且无未关闭阻塞 → `gh issue develop` 建分支并**绑定** Issue → 指派给作者 → 留开工声明 → `in-progress`。分支名 `<type>/<issue#>-<slug>`，`type ∈ {slice,fix,hotfix,spike,chore}`，slug 只允许 `[a-z0-9-]` 且**从标题推导（没有覆盖开关）**；`policy/branch-name` 会**逐字**校验这条正则，并要求 Issue OPEN 且已有 `status/*` 标签。

**`type` 显式给（尤其 hotfix）**：不给 `--type` 时按标签推导（`type/hotfix`→`hotfix`、`type/bug`→`fix`、`type/spike`→`spike`、`type/chore`→`chore`，其余→`slice`），但 **Issue 表单的下拉不会打标签**：`bug.yml` 的「线上故障」**不会**打 `type/hotfix`，漏打就让热修**静默**变成 `fix/`。所以**线上故障**一律 `scripts/start.sh <issue#> --type hotfix --as author`（唯一不会退化的路径；想用标签推导必须先**手动**加 `type/hotfix`）；未显式 `--type` 且推导为 `fix` 时脚本打印 `[WARN]` 要求复核。其它轨道：显式 `--type` 与 `type/*` 标签任选其一。

### W3 实现与提交

`bash -n scripts/*.sh`。提交：`git -c user.name="yes8080-dev-bot" -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" commit -F /tmp/msg.txt` —— 提交者身份必须**显式**指定（`--as author` 只切 `gh` 的 API 身份，不改 git 身份），信息用 `-F <文件>`（反引号/多行内联进命令行会被 shell 吃掉）；收尾前工作区必须干净（`deliver.sh` 会拦）。

### W4 交付 PR — `scripts/deliver.sh <issue#> --prepare --as author` → `scripts/deliver.sh <issue#> --as author`

门禁（本地预演，与 `policy/*` 同一套）：**先做只读状态预检**（`--check-transition <cur> in-review`，非法则在**推送之前**失败，不写骨架、不推送、不建 PR）／正文含 `Closes #N`（**标题里的关键字无效**）／含 `## 1.` … `## 6.` 六段且每段有实质内容／分支名合规且分支里的 issue 号 = 传入的 issue 号。
该分支**已有** PR（返修场景）时只推送并改用 REST PATCH 更新正文（§已知陷阱 7）；PR 标题固定取 Issue 标题（**没有覆盖开关**）。

### W5 必需检查（5 个，逐字）— `gh pr checks <pr#> --required`

| context（= job `name:`） | 判什么 |
|---|---|
| `ci/lint` | 被跟踪脚本的 `bash -n` + bash 3.2 兼容（禁 bash4 特性、`$VAR` 后不得紧跟中文）+ JSON 有效 |
| `ci/test` | 关键不变量：5 个 context 与工作流 job 名**精确相等**、规则集形状、状态标签互斥、**状态迁移是 HTTP 层单请求**（stub `gh` 断言 1 次写请求 + 载荷含全部非 `status/*` 标签，含反向样本）、PR 模板六段、无凭据入库、脚本自包含、docs↔status.sh 状态迁移表逐字一致（状态集 + 边集，读 `TRANSITIONS` 标记区） |
| `policy/linked-issue` | 正文有 `Closes #N` **且** GitHub 解析出了关闭关系（目标必须是默认分支） |
| `policy/branch-name` | 分支名匹配正则 + Issue OPEN + 已有 `status/*` 标签 |
| `policy/template` | 正文有 `## 1.` … `## 6.` |

全部 `pass` 才能进 W6；某项永久 `pending` → §已知陷阱 1、2。

### W6 独立评审 — `scripts/review.sh <pr#> approve --body-file review.md`（或 `request-changes`）

必须由 `@yes8080-reviewer-bot` 发（`review.sh` 用评审凭据，**不加** `--as`；凭据必须在**工作区之外**，见 §0 —— 落在仓库内脚本直接拒绝执行）。评审通过 → **不迁移状态**（停在 `in-review`）；打回 → `in-progress`（平台 `reviewDecision=CHANGES_REQUESTED`；在**同一分支**继续提交，不新建分支/PR）。`require_last_push_approval`：返修后新推送会**驳回旧批准**，必须重新评审。

### W7 合并与收尾（dispatcher）

`gh pr merge <pr#> --squash --delete-branch`（只有 `@yes8080` 能做）→ `scripts/closeout.sh <pr#>` 五项：① PR 已 MERGED ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地无头分支已清理 ⑤ 无残留状态标签。第 ⑤ 项**由 `closeout.sh` 自己清理**（内部调用 `status.sh <n> done`，仅对已关闭的 Issue；OPEN 的 Issue 绝不代关，否则掩盖「合并没关单」）；第 ④ 项**先**把「分支名 + 本地 tip SHA + PR head SHA + squash 提交」写进 Issue 作为可恢复锚点，**再** `git branch -D`（squash 后原始提交不在 `main` 上，`-d` 必然拒绝；但绝不允许无条件 `-D`）。

### W8 终止/取消（异常路径出口）— `scripts/abort.sh <issue#>`

W0..W7 只覆盖「一路顺风」。`canceled` 是**既有终态**（无出边、不新造状态），但此前它没有步骤/执行者/判据，分支实体在异常路径上也没有清理者 —— #60 的孤儿分支就是后果（Issue 已 `canceled`，远端分支仍留着，**无 PR、无任何门禁能看到**）。

| 项 | 规定 |
|---|---|
| 谁可发起 | 作者（PR 关闭不合并 / 中途放弃）或 PM·dispatcher（决定不做）；发起时在 Issue 留一句原因 |
| 谁确认 | dispatcher（`@yes8080`）确认「确实不做」；清理动作由**作者身份**执行（`--as author`，分支属作者），但状态迁移只走 `status.sh` |
| 判据（全部成立才终止） | ① 不再计划完成（不做 / 被替代 / 放弃）② 删除分支**不会丢内容**（见下方判据） |
| 必须同时做 | 清理**本地 + 远端**分支；状态 → `canceled`（**只走 `scripts/status.sh`**，绝不直接改标签）；在 Issue 留**可恢复锚点**（分支 tip SHA / 原因 / 时间 / 判据） |

三条异常路径共用同一命令（脚本按平台事实自动识别路径并写进锚点）：① PR 关闭不合并（PR `CLOSED` 且未 MERGED）② 作者中途放弃（有分支，可能从未有 PR）③ Issue 已取消但分支残留（`CLOSED(not planned)` + 分支残留）—— 都是 `scripts/abort.sh <issue#>`。

**删除判据（fail-closed）**：只有能证明「内容不会丢」才删 —— ① 分支 tip（本地与远端都算）是 `origin/main` 的**祖先**，或 ② 该分支有**已合并** PR（squash 后 tip 不在 `main` 上，但内容已合入），或 ③ 显式 `--evidence "<说明>"`（人工声明内容已另有归宿，声明**原文**写进锚点；**没有**无记录强删的开关）。三条都不成立（存在独有未合并提交）→ **一个分支都不删、状态也不迁移**，打印分支 tip、独有提交与处置选项后退出 1；可恢复锚点写不进去同样不删。**幂等**：连跑两次，第二次零写操作。`done` 是终态且属合并收尾 → 走 `closeout.sh`，`abort.sh` 拒绝处理（除分支外的内容会丢，需先 `gh issue reopen`）。

## 3. DoD（什么算做完；**唯一权威** —— AGENTS 只链接本表，不复述）

- [ ] Issue 有开工声明与进度评论；验收标准**逐条**有可核对证据（命令 + 输出 / 检查名 / 运行链接）
- [ ] 分支已推送、PR 已开且正文含 `Closes #N` 与六段；第 3 节回滚方式**可执行**
- [ ] 5 个必需检查在该 PR 的**最新 SHA** 上全部通过，且至少 1 名非作者 code owner 批准（`reviewDecision=APPROVED`）
- [ ] 未越界：只改了 Issue「边界」内的内容
- [ ] `closeout.sh` 五项全过（含「无残留状态标签」；合并后由 dispatcher 跑）
- [ ] 新发现的坑已写进本文件 §已知陷阱

## 4. 已知陷阱（均有原始证据，别再踩）

1. **必需检查不能"先失败后通过"。** 一旦某个必需 check 在某个 SHA 上留下 `FAILURE`，**后续同名检查通过也无法解除阻塞**（实测：`reviewDecision=APPROVED` + 全部 checks 最新一次 success，仍 `BLOCKED`）。→ 验收门禁只用**原生规则**（`required_approving_review_count: 1` + `require_last_push_approval` + `dismiss_stale_reviews_on_push`）。
2. **必需检查的 context = 工作流里 job 的 `name:`**，不是文件名、不是 workflow `name:`。改 `name:` = 所有 PR 永久 pending。也不要给必需检查工作流加 `paths`/`branches` 过滤（被跳过的工作流 = 检查永久 pending），更不要用 `issue_comment` 触发（官方只认 `push`/`pull_request`/`pull_request_review`/`pull_request_target`/`deployment`/`deployment_status`）。`merge_group` **未接线**（本仓库私有且非 GHEC，Merge Queue 不可用）—— 若将来启用 Merge Queue，**必须**同时给 5 个 job 接上 `merge_group`，否则合并队列会因必需检查未上报而永久卡住。
3. **规则集只能按「整份」比对，目标只能用 `~DEFAULT_BRANCH`。** `**` 通配符会让切片分支合并后删不掉；`git push --dry-run` **不评估** repository rules，不能用来判断规则集是否生效（真正阻止直推 `main` 的是 `pull_request` 规则：`push declined due to repository rule violations`）。声明的唯一判据是 `RULESET_CANON_JQ` **全量键 diff**（同一段文本同时出现在 `scripts/preflight.sh` 与 `ci/test`，由 `ci/test` 断言逐字一致）：挑字段比对曾让线上多出的 `require_extra_approval_for_unattributed_changes: true` / `required_reviewers: []` 静默漂移很久。语义：`require_extra_approval_for_unattributed_changes` = 含**无法归属到 GitHub 身份**的提交时需**额外批准**（历史提交作者邮箱 `wsmsn@msn.com`/`10019@outlook.com` 不可归属 → 这类 PR **可能要求多于 1 个批准**）。改这个文件属 dispatcher 权限；改键集时 `ci/test` 的全量键清单要同步改（有意的摩擦）。
4. **CODEOWNERS 里任何会被改动的路径都必须至少有一个"非作者" owner。** 若某路径 owner 只有作者本人而 `require_code_owner_review=true`，该路径的改动**永久无法合并**。且 CODEOWNERS **取自目标分支** —— 在 PR 里改它无法为该 PR 自己解锁。
5. **作者的 classic PAT 只有 `repo` + `workflow`，没有 `read:org`。** `gh pr edit` 走 GraphQL、需要 `read:org` → 报 `Your token has not been granted the required scopes ... 'read:org'` 且**静默不更新正文**。改 PR 正文必须用 REST：`jq -Rs '{body:.}' file | gh api -X PATCH repos/$REPO/pulls/$N --input -`，并在写后**回读校验**（`deliver.sh` 已封装）。
6. **推送必须清掉本地 credential helper**：`git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin <branch>` —— 否则 macOS 钥匙串里缓存的主身份凭据会优先命中，"作者身份推送"会静默变成主身份推送。
7. **macOS 自带 bash 是 3.2。** 禁 `mapfile`/`readarray`/`declare -A`/`${var,,}`；`$VAR` 后紧跟中文等多字节字符必须写 `${VAR}`，否则字节序列被并入变量名 → `unbound variable`。`sed` 是 BSD 版：扩展正则要用 `sed -E`。
8. **`blockedBy` 不会因对方关闭而自动清除。** 判定"是否真被阻塞"必须看 blocker 的 `state`。
9. **squash 合并后 `git branch -d` 必然拒绝**（原始提交不在 `main` 上）。先验证 PR=MERGED，留锚点，再 `-D`；绝不无条件 `-D`。
10. **状态迁移的判据是「HTTP 层单请求」，不是「一次 CLI 调用」。** 约束：带标签 → 带标签（`ready`/`in-progress`/`in-review`）的迁移**只能有一条 HTTP 写请求** —— REST `PUT /repos/{owner}/{repo}/issues/{n}/labels`（**整份替换**），实现只有一处：`status.sh` 的 `STATUS_LABELS_PUT` 标记区（读 → 改 → 写 → **读回校验**）。历史证据：v2 重写拆成 remove+add 两次调用（PR #92 首 SHA `cc9cf14` 实测 `14:06:13Z` unlabeled → `14:06:16Z` labeled，约 3 秒零标签窗口）；`#93` 合成「一次 `gh issue edit`」把窗口压到毫秒级但**非零** —— cli/cli 在 HTTP 层仍把它拆成 `addLabelsToLabelable` / `removeLabelsFromLabelable` 两个**并发** mutation（v2.102.0 `pkg/cmd/pr/shared/editable_http.go:13,17-36,91`），中间态可能是 0 个或 2 个 `status/*`，而 `policy/branch-name` 对两者都判失败、失败的 SHA **不可逆**（陷阱 1）。代价：`deliver.sh` 的次序是「推送 → 建 PR → 迁 `in-review`」，PR 事件**立刻**触发必需检查，窗口内读到 0 个标签就把 Issue 判成 Backlog。
    两条硬约束：① 载荷**必须**带上读到的**全部非 `status/*` 标签**（`type/*`、`role/*` …）—— 整份替换只发 `status/*` 会**静默删掉**别人的标签；② 读-改-写之间有并发覆盖风险 → 写后**读回校验**一次，非 `status/*` 集合不一致就**报告并退出、不重试覆盖**（重试只会再抹一次对方的改动）。三类迁移的载荷不同：带标签→带标签 = 非 `status/*` + 目标标签；→ `backlog` = 非 `status/*`（状态移除即结果）；→ `done`/`canceled` = 非 `status/*`，**先**整份替换、**后** `gh issue close`（关闭不改标签，且不触发 `pull_request: opened|synchronize`）。
    **判据（常驻 `ci/test`，不新增必需检查）**：stub `gh` 跑**真实** `status.sh`，断言非终态迁移**恰好 1 次**标签写请求（且 0 次 `gh issue edit`）、载荷含全部非 `status/*` 标签；**反向样本**内置 —— 改回两次写请求、或载荷漏带 `type/*` → 该断言**必须失败**；读回校验用「写后他人又改了标签」的 stub 场景验证它**报告且不重试覆盖**。判据写在 `ci/test`（不在 `/tmp` 跑一次），改实现时它必须仍然能失败。
11. **脚本里用 tab 当字段分隔符会静默吞掉空字段。** `IFS="$(printf '\t')" read -r a b c` 遇到连续 tab（中间字段为空）时后面的字段会**左移** —— tab 属于 IFS 空白，连续空白只算一个分隔符。`--check-cross` 的早期实现因此在「按行分类」时静默失配（Issue 的 `stateReason` 空字段把标签字段顶位）。脚本内部的记录分隔改用**非空白字符**（本仓库用 `|`）或给空值写占位符；这类差别必须能用反向样本抓到（见 W8 与 §1 交叉体检）。
12. **Issue 表单不会打标签，标签也没有清单。** `bug.yml` 的「轨道」下拉选「线上故障」**不会**给 Issue 打 `type/hotfix`（表单只有固定的 `labels:` 数组），而 `start.sh` 靠 `type/*` 推导分支类型 —— 漏打标签就让热修**静默退化成 `fix/`**（Issue #103）。线上故障一律用 `scripts/start.sh <issue#> --type hotfix --as author`。标签是仓库级对象（`status.sh --add-label` 遇不存在的标签直接失败），所以机器消费的标签由 `preflight.sh` 与 `ci/test` 用同一判据 `LABEL_ASSERT` 断言存在，`ci/test` 里还留了反向样本（删掉 `type/hotfix` 后断言必须失败），防止判据退化成空断言。
13. **凭据隔离的范围（已知局限）：文件隔离只是提高了门槛，不是防线本身。** `#94` 把两个身份凭据都放到工作区之外（`$HOME/.config/pm4gh/`），它**提供**的是：**工作区边界**（凭据落在仓库根内 → `review.sh` 报错退出、`preflight.sh` 记 `[FAIL]`，机器可查）与**杜绝提交/泄露**（不可能被 `git add` 误提交、不会撞 `ci/test` 的凭据扫描）。它**不提供**：**同一 OS 用户下两个凭据文件之间的身份隔离** —— 作者本来就要读 `developer.pat`，同一用户能列 `$HOME/.config/pm4gh/` 就读得到同目录的 `reviewer.pat`；文件层面**不构成身份隔离**（PM 裁定方案 1 的配套声明，`#94`）。因此三身份分离的**真正强制点是平台与契约**：① **平台** —— GitHub 拒绝自我批准（`Review Can not approve your own pull request`）+ 规则集 `require_code_owner_review` / `require_last_push_approval`；② **流程契约** —— [AGENTS.md §5.1](../AGENTS.md)（作者不得读取其他身份凭据）。**禁止**把这条写成"作者取不到评审凭据"或等价说法 —— 假装隔离成功比承认没隔离更危险。

## 5. 明确不做（边界）

不做「装到别人仓库」（无安装器/卸载器）｜不做 Projects｜不做度量报表｜不做跨模型评审留痕｜不做能力开关｜不做共享库（每个脚本自包含）｜不做要求审批才能通过的自定义验收检查｜**不引入第二套规范文档**（流程只在仓库里：本文件 + `AGENTS.md` + `.github/**` + `scripts/**` 就是全部权威；元工具自身的代码量超过它服务的开发工作，就是失控信号）。
**理由：本项目的价值是"多 agent 用 GitHub 跑开发"，不是发布工具。**
