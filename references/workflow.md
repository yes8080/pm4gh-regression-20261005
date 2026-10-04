# workflow — 多 agent + GitHub 开发流程（细节与判据）

> 本文件是流程的**细节权威**（步骤 / 判据 / 陷阱）。指令与规则摘要见 [../SKILL.md](../SKILL.md)。
> 命令一律在**仓库根目录**执行；占位符 `<n>` / `<pr#>` 只填**数字**（不要带 `#`，脚本会拒绝）。
> 冲突时以 **GitHub 平台实际行为**为准；发现冲突**必须**开 Issue 改文档，**禁止**按"更方便"执行。
> `--dry-run`（`start.sh` / `deliver.sh` / `closeout.sh` / `abort.sh` 支持；其余脚本无此开关）。
> `--dry-run` = 不建分支、不推送、不建 PR、不写 Issue、不删分支、不迁移状态；`closeout.sh --dry-run` 仍判五项，判不过就退出码 `1`。
> **例外**：`deliver.sh --prepare --dry-run` 仍会写正文骨架文件（`cat >` 在 `--dry-run` 判断之前执行）—— 用它预演时要自己有数。

## 0. 三身份（**唯一权威**）

**何时用本小节**：开工前（W0）读一遍确认自己该用哪份凭据；每次调用 `review.sh`（W6）前再确认评审身份。

| 角色 | 账号 | 凭据（**必须在工作区之外**） | 职责 |
|---|---|---|---|
| 作者 | `@yes8080-dev-bot` | `$HOME/.config/pm4gh/developer.pat`（scope `repo, workflow`） | 建分支、提交、推送、开 PR、返修 —— **只加** `--as author` |
| 评审 | `@yes8080-reviewer-bot` | `$HOME/.config/pm4gh/reviewer.pat`（scope `repo`） | `review.sh <pr#> approve\|request-changes` —— **不加** `--as`，**不得合并** |
| 合并 | `@yes8080` | 本机 `gh auth login` 登录态（不用凭据文件） | `gh pr merge --squash`、改仓库设置、`closeout.sh` |

- **必须**：`--as` 只传 `author`；**禁止**用任何脚本把作者"切换"成 dispatcher。
- **禁止**：读取其他身份的凭据内容（作者不读 `reviewer.pat`）；打印或提交任何凭据。
- **必须**：两个身份凭据都放在**工作区之外**；工作区内出现 `*.pat` → `preflight.sh` 记 `[FAIL]`。
- **判据**：`review.sh`（W6）只做位置判据 —— 把 `REVIEWER_PAT_FILE` 解析成绝对路径（`cd … && pwd -P`），落在仓库根之内 → 拒绝执行（退出码 `1`）。
- **判据**：`preflight.sh`（W0）断言工作区内不存在任何 `*.pat`（含作者凭据）；作者凭据本身只查权限 600 与"未被 git 跟踪"。

### W0 身份开通：凭据放哪

**何时用本小节**：`preflight.sh` 报凭据缺失 / 落在工作区内时（由 PM·dispatcher 在**工作区外**执行）。

```bash
mkdir -p "$HOME/.config/pm4gh" && chmod 700 "$HOME/.config/pm4gh"
# 在 GitHub → Settings → Developer settings 生成 classic PAT：
#   作者 scope = repo, workflow；评审 scope = repo
printf '%s\n' '<作者 PAT>' > "$HOME/.config/pm4gh/developer.pat"
printf '%s\n' '<评审 PAT>' > "$HOME/.config/pm4gh/reviewer.pat"
chmod 600 "$HOME/.config/pm4gh/developer.pat" "$HOME/.config/pm4gh/reviewer.pat"
```

- **必须**：`preflight.sh` 断言工作区内**不存在任何** `*.pat`（`find . -name '*.pat'`）。
- **可选**：换别的工作区外路径 → `REVIEWER_PAT_FILE=/工作区外/路径 scripts/review.sh <pr#> approve --body-file <文件>`。
- 许可与禁止口径见 [../SKILL.md](../SKILL.md)「禁止」一节；隔离的强度边界见 §4 陷阱 13。

## 1. 状态机（唯一源）

**何时用本小节**：每一步动手改状态之前；调用 `scripts/status.sh` 之前查本节的出边与退出码。

- **必须**：状态迁移**只能**走 `scripts/status.sh <n> <state>`；**禁止**直接改标签、**禁止**把状态写进本地文件。
- **必须**：任何不可逆副作用（建分支 / 推送 / 建 PR）**之前**先跑只读判定：
  `scripts/status.sh --check-transition <from> <to>` → 退出码 `0` 合法 / `1` 非法 / `2` 用法错。
- **判据**：`scripts/status.sh <n> <state>` 退出码 `0` 成功 / `1` 校验或迁移失败 / `2` 参数错。
- **禁止**：表外 `from → to`（含 `done` / `canceled` 出边、跨级跳跃）—— 一律失败，**没有跳过开关**。
- **必须**：需要例外就开 Issue 补一条边，同时改 `scripts/status.sh` 的 `TRANSITIONS` 与本表（`ci/test` 断言两处逐字一致）。
- 状态集 **6 个**：`backlog | ready | in-progress | in-review | done | canceled`。
- `in-review` = 「评审中 / 已批准待合并」；没有单独的「验收」状态。
- 「被打回」**不设独立状态**：打回 = `in-review → in-progress`（平台另有 `reviewDecision=CHANGES_REQUESTED`）。

### 状态迁移表（**唯一表权威**：6 个状态、15 条边；与 `scripts/status.sh` 的 `TRANSITIONS` 由 `ci/test` 断言**逐字一致**）

**何时用本小节**：任何一次状态迁移之前 —— 先在这里查 `from` 的合法出边与触发者，再敲命令。

> 转换表**只用表**：一行一条边，可 grep/awk 校验；**禁止**画图。
> `类型` 取值：`正常` = 主路径推进；`异常` = 回退 / 打回 / 终止。
> `终态` = 进入 `done`（切片 = 合并关单；非切片 = 待办项全部关闭，见「`done` 的三层语义」）或终态本身（无出边）。
> 表内 `done` / `canceled` 两行是**终态说明行**（无出边），不计入 15 条边；比对口径 = `TRANSITIONS` 里的 from→to 集合。
> `from == to`（同状态）视为**幂等合法**：`status.sh` 直接返回 `0`，不改任何东西。

<!-- TRANSITIONS:BEGIN（机器可读；与 scripts/status.sh 的 TRANSITIONS 逐字一致，由 ci/test 断言；首列 = 状态集，其余反引号 token = 出边） -->

| from | to | 触发者 | 命令/事件 | 类型 |
|---|---|---|---|---|
`backlog` | `ready` | 人/PM | W1 DoR 五项齐备 | 正常
`backlog` | `in-progress` | dev-bot | W2 start.sh 直接开工（不假定 Issue 在 backlog） | 正常
`backlog` | `done` | 人/PM·dispatcher | 非切片 Issue（Epic / Audit / 提案）收尾：待办项已**全部**关闭 → `scripts/status.sh <n> done` | 终态
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

#### `done` 的三层语义（`backlog → done` 的边界）

**何时用本小节**：只有**非切片** Issue（Epic / Audit / 提案）要收尾，或不确定该走 `in-review → done` 还是 `backlog → done` 时。

| 场景 | 合法路径 | 含义 |
|---|---|---|
| 切片（Issue → 分支 → PR） | `in-review → done` | 已经过评审并合并、收尾完成（W7 + `closeout.sh`） |
| 非切片（Epic / Audit / 提案） | `backlog → done` | 该 Issue 的待办项已全部关闭（它自己不产出 PR） |
| 不做（任意非终态状态） | `→ canceled` | 不做（`state_reason=not_planned`）—— 与 `done` 的区别正是 `state_reason` |

- **必须**：切片要进 `done`，`in-review` 是**必经**状态；**禁止**用 `backlog → done` 替代 `in-review → done`。
- **判据**（`backlog → done` 之前逐项确认，三条全成立）：① 不是切片（切片走 W2..W7）② 无未关闭的待办子项 ③ 无关联 PR。

### 状态载体与体检

**何时用本小节**：怀疑某个 Issue 有 0 个或 2 个 `status/*` 标签时（例如 `policy/branch-name` 判失败）。

- 载体：`ready`/`in-progress`/`in-review` = 对应 `status/*` 标签（**互斥**）；`backlog` = Issue OPEN 且无 `status/*`。
- 载体：`done`/`canceled` = Issue CLOSED（`state_reason=completed` / `not planned`）**且**无任何 `status/*` 标签。
- **必须**：`scripts/status.sh --check`（扫全部开放 Issue，每个必须 0 或 1 个 `status/*`）退出码 `0`；`ci/test` 每次 PR 跑同一不变量。
- **必须**：`scripts/status.sh --check-transition <from> <to>` 在 `start.sh` / `deliver.sh` 的副作用之前被调用（两脚本自己调用）；**禁止**先建分支或先推送再判。

### 交叉体检（只读，Issue ↔ PR）— `scripts/status.sh --check-cross`

**何时用本小节**：发现「Issue 已 `in-review` 而关联 PR 被关闭」这类不一致时；`--check`、`ci/test`、`policy/*` 都只读 Issue，兜不住这类冲突。

| 规则 | 判据 |
|---|---|
| R1 | Issue 为 `in-review`，但关联 PR 已 `CLOSED`（未合并） |
| R2 | Issue 为 `done`，但关联 PR 未合并（仍开放 / 已关闭未合并） |
| R3 | Issue 为 `in-review`，但**没有任何开放 PR** |
| R4 | 有开放 PR，但 Issue 无任何 `status/*`（Backlog） |

- **判据**：退出码 `0` = 四条全未命中；`1` = 存在冲突（逐条打印规则、Issue/PR 号与关联方式）；`2` = 查询失败 / 用法错。
- 「关联」只认两种可判定证据：PR 的 `closingIssuesReferences`，或分支名 `<type>/<issue#>-<slug>`。
- **禁止**猜测两者都没有的 PR —— 如实标注「无法判定」并列出，不计入冲突。
- **禁止**：把本命令当成写操作 —— 它零副作用（只发 GET、只写临时目录）。

### 标签族定位（**唯一一处**声明）

**何时用本小节**：要新增 / 删除 / 引用一个标签时，先查它是不是机器消费的。

| 标签族 | 定位 |
|---|---|
| `status/*` | **消费者**：`status.sh`（唯一迁移入口）/`start.sh`/`deliver.sh`/`abort.sh`/`closeout.sh`/`ci/test` |
| `type/*` | **消费者**（仅 `bug`/`hotfix`/`spike`/`chore`）：`start.sh` 据此推导分支类型；`task`/`feature` 无消费者 → 人类元数据 |
| `prio/*`、`risk/*`、`role/*`、`area/*`、GitHub 默认标签 | **人类元数据（机器不读）**：只供人筛选 |
| `src/*`、`size/*` | **不存在**。**禁止**引用或重建；`status/rework` 同样**禁止**引用 |

- **判据**：机器消费的标签由 `preflight.sh`（W0）与 `ci/test`（每次 PR）用**同一段判据**（`LABEL_ASSERT`）断言存在。
- **判据**：`ci/test` 断言两处逐字一致，并带反向样本（删掉 `type/hotfix` → 断言必须失败）。
- 新增机器消费标签时**必须**同步三处：`preflight.sh` 的 `MACHINE_LABELS`、`ci/test` 的同一段副本、线上标签本身（由 dispatcher 加）。

## 2. W0..W8 闭环

**何时用本小节**：每接一个 Issue 从 W0 开头顺做；知道自己在第几步，就翻对应小节。

### 时序步骤表（谁在什么时候触发）

**何时用本小节**：确认自己在整个闭环的哪一步、下一步归谁时。

| # | 角色 | 动作 | 产物/门禁 | 失败·返修 |
|---|---|---|---|---|
| 1 | 人/PM | 交 Issue + 验收标准（DoR 五项） | Issue（W1）；此前状态 `backlog`（OPEN 且无 `status/*`） | DoR 不齐 → 留在 `backlog` 补齐 |
| 2 | dev-bot | W2 `scripts/start.sh <issue#> --as author`：建分支 + 绑定 Issue + 指派给作者 | 分支 `<type>/<issue#>-<slug>`；状态 `in-progress`（W0 预检全过） | 只读状态预检非法 → **建分支之前**失败 |
| 3 | dev-bot | W3 实现 + 提交（作者身份，`commit -F`） | 提交；工作区干净；`bash -n scripts/*.sh` 通过 | 语法 / bash 3.2 兼容性失败 → 先修 |
| 4 | dev-bot | W4 `scripts/deliver.sh <issue#> --as author`：推送并开 PR / 更新正文 | PR 正文含 `Closes #N` + 六段；状态 `in-review` | 缺 `Closes #N` / 六段 → 推送前失败 |
| 5 | CI/规则集 | W5 `gh pr checks <pr#> --required`（PR 事件自动触发） | `ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template` 全 `pass` | 任一失败 → 修后同分支再推（走 #7） |
| 6 | reviewer-bot | W6 `scripts/review.sh <pr#> approve --body-file <文件>`（**不加** `--as`；禁止自批） | `reviewDecision=APPROVED` → 停在 `in-review`（已批准待合并） | `request-changes` → 状态 `in-progress`（同分支返修） |
| 7 | dev-bot | 返修：**同一分支**继续提交（不新建分支/PR）后 `deliver.sh` 再推 | 新 SHA；必需检查在新 SHA 重跑；状态回到 `in-review` | `require_last_push_approval` 驳回旧批准 → 必须回 #6 重评 |
| 8 | dispatcher | W7 `gh pr merge <pr#> --squash --delete-branch`（只有 `@yes8080` 能做） | Issue 自动关单 → 状态 `done` | 缺批准 / 必需检查未过 → 合并被拒 |
| 9 | dispatcher | `scripts/closeout.sh <pr#>` 五项核验 | ① PR MERGED ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地无头分支已清理 ⑤ 无残留 `status/*` 标签 | 任一项不过 → 贴原文报告；⑤ 由脚本自己跑 `scripts/status.sh <n> done` |

> 顺序之外只有 W8：异常路径出口 → `scripts/abort.sh <issue#>` → `canceled`。

### W0 预检（每次接手都跑）— `scripts/preflight.sh`

**何时用本小节**：接手任何 Issue 的**第一步**；或 `preflight.sh` 报错后按提示修完复跑。

```bash
scripts/preflight.sh
```

- **判据**：无参数；全部 `[ OK ]` 且退出码 `0`。任一 `[FAIL]` → 退出码 `1`。
- 有 `[FAIL]` 时**禁止**"先干着看"，把失败项**原文**贴给 dispatcher。
- 脚本按 `1/10` … `10/10` 输出十组，逐组给结论。
- 组①命令齐备；②gh 登录；③仓库形态与 cwd；④工作区与远端；⑤三身份凭据（作者 scope/权限/未入库 + 评审凭据位置）。
- 组⑥⑦⑧规则集与必需 context（含线上/文件整份 diff）；⑨机器消费标签存在；⑩工作区内无凭据文件且未被 git 跟踪。
- **判据**：只有 `[FAIL]` 计入失败数；`[WARN]` 一律不阻断（退出码仍 `0`）。
- 常见 `[WARN]`：工作区有未提交改动、本地 `main` 与 `origin/main` 不一致、无法 fetch、评审凭据缺失、作者权限异常、超过一个 `in-progress`。
- 组⑦⑧需要 `.github/workflows/*.yml` 存在 —— 在**没有**工作流的副本里跑必然 `[FAIL]`，这是环境事实，不是本流程失败。

### W1 领片（DoR）

**何时用本小节**：从 `ready` 队列挑片，或要把一个 `backlog` Issue 置为 `ready` 时。

```bash
gh issue list --state open --label status/ready --limit 20 --json number,title,labels
scripts/status.sh --check-transition backlog ready     # 只读；退出码 0 = 合法
scripts/status.sh <n> ready                            # 退出码 0 = 迁移成功
```

- **判据**（五项全齐才可 `backlog → ready`）：① 价值一句话 ② 可判定的验收标准 ③ 明确不改什么（边界）④ 依赖与契约 ⑤ 规模与执行者。

### W2 开工 — `scripts/start.sh <issue#> --as author`

**何时用本小节**：Issue 进入 `ready` 后（或 `backlog` 直接开工）；**返修不走这里**（返修在原分支继续提交）。

```bash
scripts/start.sh <issue#> --as author                          # 常规
scripts/start.sh <issue#> --type hotfix --as author            # 线上故障（必须显式给 --type）
```

- **判据**：退出码 `0`；分支 `<type>/<issue#>-<slug>` 已由 `gh issue develop` 创建并**绑定** Issue；Issue 已指派给作者；开工声明评论已提交；状态 `in-progress`。
- **禁止**：手工 `git checkout -b`（不会建立 Issue 绑定）；**禁止**假定 Issue 停在 `backlog`（脚本读平台当前状态）。
- 非法的当前状态（例如 `in-review`）→ **在创建分支之前**失败，不留半成品。
- **判据**：退出码 `0` 成功 / `1` 校验或迁移失败（当前状态非法、参数错都是 `1`）。
- `type ∈ {slice,fix,hotfix,spike,chore}`；slug 从标题推导（`[a-z0-9-]`，**没有覆盖开关**）。
- **判据**：`policy/branch-name` 逐字校验 `^(slice|fix|hotfix|spike|chore)/[0-9]+-[a-z0-9-]+$`，并要求 Issue OPEN 且已有 `status/*` 标签。
- **线上故障必须显式给 `--type hotfix`**（显式 `--type` 优先于标签）。
- 不给 `--type` 时脚本按标签推导：`type/hotfix`→`hotfix`、`type/bug`→`fix`、`type/spike`→`spike`、`type/chore`→`chore`，其余→`slice`。
- **违反后果**：Issue 表单的下拉**不会**打标签 —— 漏打会让热修**静默**退化成 `fix/`。
- **判据**（想靠标签推导时）：先手动加 `type/hotfix` 标签再重跑；未显式 `--type` 且推导结果为 `fix` 时脚本打印 `[WARN]`，**必须**复核。
- 其它轨道（`slice`/`fix`/`spike`/`chore`）：显式 `--type` 与 `type/*` 标签**任选其一**（显式优先）。

### W3 实现与提交

**何时用本小节**：分支已建、开始写代码时；每次提交前。

```bash
git add -A                       # 暂存本次改动（范围 = Issue「边界」内的文件）
bash -n scripts/*.sh
scripts/status.sh --check
git -c user.name="yes8080-dev-bot" -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" commit -F <消息文件>
```

- **判据**：`bash -n scripts/*.sh` 退出码 `0`；`scripts/status.sh --check` 退出码 `0`。
- **必须**：提交者身份显式指定（`--as author` 只切 `gh` 的 API 身份，**不改** git 身份）。
- **必须**：提交信息用 `-F <文件>`（反引号 / 多行内联进命令行会被 shell 吃掉）。
- **必须**：`deliver.sh` 之前工作区干净（有未提交改动时 `deliver.sh` 直接失败）。
- **禁止**：`mapfile` / `readarray` / `declare -A` / `${var,,}`；`$VAR` 后紧跟中文**必须**写 `${VAR}`；BSD `sed` 扩展正则**必须**加 `-E`。

### W4 交付 PR — `scripts/deliver.sh`

**何时用本小节**：实现完成、提交完成，要推送并开 PR / 更新已有 PR 正文时。

```bash
scripts/deliver.sh <issue#> --prepare --as author      # 生成六段骨架（默认 .git/PR_BODY_<issue#>.md）
# 填写六段（--body-file <文件> 可换路径）
scripts/deliver.sh <issue#> --as author                # 校验 + 推送 + 建 PR / 更新正文
```

- 默认正文文件 = `.git/PR_BODY_<issue#>.md`；`--prepare --body-file <文件>` 换路径后，**最终那条命令也要带同一个** `--body-file <文件>`。
- PR 标题由脚本生成 = `<Issue 标题> (#<issue#>)`（标题取自 Issue 标题，脚本自己追加 issue 号，**没有覆盖开关**）。
- **判据**：退出码 `0`；正文含 `Closes #N`（**PR 标题里的关键字无效**）。
- **判据**：正文含 `## 1.` … `## 6.` 六段、每段非空白字符 ≥ 20。
- **判据**：分支名合规且分支里的 issue 号 = 传入的 issue 号；工作区干净；推送成功；PR 已建或正文已更新并**回读一致**；状态 `in-review`。
- **必须**：先跑 `status.sh --check-transition <cur> in-review`（脚本自己做）—— 非法则**在推送之前**失败，不写骨架、不推送、不建 PR。
- **判据**：退出码 `0` 成功 / `1` 校验或迁移失败（`--prepare` 同样受状态预检约束）。
- 当前状态为 `backlog`/`ready` → 先 `scripts/start.sh <issue#> --as author`。
- 该分支**已有** PR（返修场景）时只推送，并改用 REST PATCH 更新正文（脚本已封装 + 回读校验）：
  `jq -Rs '{body:.}' <文件> | gh api -X PATCH repos/$REPO/pulls/$N --input -`。
- **禁止**：用 `gh pr edit` 改 PR 正文（走 GraphQL，作者凭据缺 `read:org` → 报错且**静默不更新**）。
- **禁止**：改 PR 标题。
- **禁止**：推送时不带 `-c credential.helper= -c credential.helper='!gh auth git-credential'`（脚本已封装）。
- **违反后果**：macOS 钥匙串缓存的主身份凭据优先命中，作者身份推送静默变成主身份推送。

### W5 必需检查（5 个，逐字）— `gh pr checks <pr#> --required`

**何时用本小节**：`deliver.sh` 推送之后、请评审之前。

| context（= job `name:`） | 判什么 |
|---|---|
| `ci/lint` | 被跟踪脚本的 `bash -n` + bash 3.2 兼容（禁 bash4 特性、`$VAR` 后不得紧跟中文）+ JSON 有效 |
| `ci/test` | 5 个 context 与工作流 job 名**精确相等**、规则集形状、状态标签互斥、状态迁移是 HTTP 层单请求（stub `gh` 断言 1 次写请求 + 载荷含全部非 `status/*` 标签，含反向样本）、PR 模板六段、无凭据入库、脚本自包含、`references/workflow.md` ↔ `status.sh` 状态迁移表逐字一致 |
| `policy/linked-issue` | 正文有 `Closes #N` **且** GitHub 解析出了关闭关系（目标必须是默认分支） |
| `policy/branch-name` | 分支名匹配正则 + Issue OPEN + 已有 `status/*` 标签 |
| `policy/template` | 正文有 `## 1.` … `## 6.` |

- 命令在**仓库根目录**执行（不带 `-R`，用当前仓库）。
- **判据**：5 个 context 在**最新 SHA** 上全 `pass` 才进 W6。
- 某项永久 `pending` → §4 陷阱 1、2。

### W6 独立评审 — `scripts/review.sh`（评审身份）

**何时用本小节**：W5 五个必需检查全 `pass` 之后（评审者）；或写返修清单要打回时（打回后在**同一分支**继续提交）。

```bash
scripts/review.sh <pr#> approve --body-file review.md                       # 通过（不加 --as）
scripts/review.sh <pr#> request-changes --body-file <返修清单文件>            # 打回
scripts/review.sh <pr#> comment --body-file <文件>                            # 只评论，不改门禁
```

- **判据**：退出码 `0` 发出评审 / `1` 校验或认证失败；`approve` → `reviewDecision=APPROVED`；`request-changes` → 平台 `CHANGES_REQUESTED`。
- **必须**：由 `@yes8080-reviewer-bot` 发（脚本用评审凭据，**不加** `--as`）。
- **必须**：approve / request-changes 给 `-m <文本>` 或 `--body-file <文件>`（**必须**给其一，否则脚本拒绝执行）。
- 同时给两者时 `-m` 优先；`review.md` 只是示例文件名，路径由调用者决定（脚本不读默认评审文件）。
- **禁止**：自批（作者批准自己的 PR）；评审身份合并。
- `approve` → **不迁移状态**（停在 `in-review`）。
- `request-changes` → 若分支里的 issue 号在 PR 的 `closingIssuesReferences` 中，脚本自动 `scripts/status.sh <n> in-progress`。
- **判据**（打回后状态已迁移）：`scripts/status.sh --check-transition in-review in-progress` 为合法边。
- **判据**：脚本打印 `[WARN] 跳过状态迁移` 时**必须**人工用 `scripts/status.sh <n> in-progress` 补。
- **判据**：返修后新推送**驳回旧批准**（`require_last_push_approval`）→ **必须**回 W6 重评。
- 门禁读数：`gh pr view <pr#> --json reviewDecision,mergeStateStatus`。

### W7 合并与收尾（dispatcher）

**何时用本小节**：`reviewDecision=APPROVED` 且 5 个必需检查全 `pass` 之后。

```bash
gh pr merge <pr#> --squash --delete-branch
scripts/closeout.sh <pr#>
```

- **判据**：`closeout.sh` 五项全过且退出码 `0`：① PR 已 MERGED ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地无头分支已清理 ⑤ 无残留状态标签。
- 任一不过 → 退出码 `1`，逐条贴原文报告。
- **禁止**：作者代跑 W7 合并；`gh pr merge --admin` 或任何绕过门禁的手段（只有 `@yes8080` 用本机登录态合并）。
- 第 ⑤ 项由 `closeout.sh` 自己清理（内部调用 `scripts/status.sh <n> done`，**仅对已关闭的 Issue**；OPEN 的 Issue 绝不代关）。
- 第 ④ 项**先**把「分支名 + 本地 tip SHA + PR head SHA + squash 提交」写进 Issue 作为可恢复锚点，**再** `git branch -D`；**禁止**无条件 `-D`。

### W8 终止/取消（异常路径出口）— `scripts/abort.sh <issue#>`

**何时用本小节**：PR 关闭不合并 / 作者中途放弃 / Issue 已取消而分支残留 —— 三种异常路径的**唯一**出口。
**触发者**：谁决定终止都可以（作者 / 人·PM / dispatcher），但**执行本命令的只能是作者身份**（`--as` 只接受 `author`）。

```bash
scripts/abort.sh <issue#> --dry-run                            # 先看它要删什么
scripts/abort.sh <issue#> --branch <分支名> --dry-run            # 自动发现不到分支时显式指定
scripts/abort.sh <issue#> --evidence "内容已由 <sha> 并入 main"  # 内容已另有归宿时
scripts/abort.sh <issue#> --reason "需求取消"                    # 附原因（写进锚点）
```

- **必须**：用作者身份执行（`--as` 只接受 `author`，默认即 `author`）。
- **必须**：`--reason` / `--evidence` 不要带 tab / 换行 / `|`（脚本会把它们替换成空格后写进锚点）。
- **必须**：清理**本地 + 远端**分支；状态 → `canceled`（**只走 `scripts/status.sh`**）；在 Issue 留可恢复锚点（分支 tip SHA / 原因 / 时间 / 判据）。
- **判据**（全部成立才终止）：① 不再计划完成 ② 删除分支**不会丢内容**。
- **删除判据（fail-closed）**：三条任一成立才删。
- 判据①：分支 tip（本地与远端都算）是 `origin/main` 的**祖先**。
- 判据②：该分支有**已合并**的 PR。
- 判据③：显式 `--evidence "<说明>"`（声明原文写进锚点）。
- **违反后果**：三条都不成立（存在独有未合并提交）→ **一个分支都不删、状态也不迁移**，
  打印分支 tip、独有提交与处置选项后退出 `1`；锚点写不进去同样不删。
- **判据**：退出码 `0` 已清理 / 幂等无操作；`1` 拒绝删除或迁移失败；`2` 用法错。**幂等**：连跑两次，第二次零写操作。
- `done` 是终态且属合并收尾 → `abort.sh` **拒绝**处理，走 `closeout.sh`；确需取消先 `gh issue reopen`。

## 3. DoD（什么算做完；**唯一权威**）

**何时用本小节**：写 PR 正文第 5 节「DoD 自查」时；dispatcher 合并前核验时。

- [ ] Issue 有开工声明与进度评论；验收标准**逐条**有可核对证据（命令 + 输出 / 检查名 / 运行链接）
- [ ] 分支已推送、PR 已开且正文含 `Closes #N` 与六段；第 3 节回滚方式**可执行**
- [ ] 5 个必需检查在该 PR 的**最新 SHA** 上全部通过，且至少 1 名非作者 code owner 批准（`reviewDecision=APPROVED`）
- [ ] 未越界：只改了 Issue「边界」内的内容
- [ ] `scripts/closeout.sh <pr#>` 五项全过（合并后由 dispatcher 跑）
- [ ] 新发现的坑已写进本文件 §4

## 4. 已知陷阱（**触发条件 + 正确动作**）

**何时用本小节**：现象与某条触发条件对上时——先查这里，再动手；不要凭直觉绕过门禁。

**1. 必需检查不能"先失败后通过"**
- 触发：某个必需 check 在某个 SHA 上留下 `FAILURE` 后，后续同名检查通过。
- **违反后果**：该 SHA 上的失败结论**不可逆**，阻塞解除不了。
- **禁止**：把验收做成自定义检查；**禁止**用 `/accept` 评论代替批准。
- **必须**：验收门禁只用原生规则（`required_approving_review_count: 1` + `require_last_push_approval` + `dismiss_stale_reviews_on_push`）。

**2. 必需检查的 context = 工作流里 job 的 `name:`**
- 触发：改 job `name:` / 给必需检查工作流加过滤 / 换触发事件。
- **禁止**：改 `name:`（不是文件名、不是 workflow `name:`）。
- **禁止**：给必需检查工作流加 `paths`/`branches` 过滤 —— 被跳过 = 检查永久 pending。
- **禁止**：用 `issue_comment` 触发（官方只认 `push`/`pull_request`/`pull_request_review`/`pull_request_target`/`deployment`/`deployment_status`）。
- **必须**：若启用 Merge Queue，同时给 5 个 job 接上 `merge_group`（现在**未接线**）。

**3. 规则集只能按「整份」比对，目标只能用 `~DEFAULT_BRANCH`**
- 触发：用 `**` 通配符 / 用 `git push --dry-run` 判断规则集是否生效。
- **禁止**：`**` 通配符（会让切片分支合并后删不掉）。
- **禁止**：挑字段比对；**禁止**用 `git push --dry-run` 判断规则集是否生效（它**不评估** repository rules）。
- **判据**：唯一判据是 `RULESET_CANON_JQ` **全量键 diff**（`preflight.sh` 与 `ci/test` 同一段文本，逐字一致）。
- **禁止**：改线上规则集或 `.github/rulesets/main-protection.json`（属 dispatcher 权限）；改键集时 `ci/test` 的全量键清单要同步改。
- 备注：`require_extra_approval_for_unattributed_changes` = 含**无法归属到 GitHub 身份**的提交时需**额外批准**（这类 PR 可能要求多于 1 个批准）。

**4. CODEOWNERS 里任何会被改动的路径都必须至少有一个"非作者" owner**
- 触发：某路径 owner 只有作者本人，而 `require_code_owner_review=true`。
- **违反后果**：该路径改动**永久无法合并**。
- **禁止**：在 PR 里改 CODEOWNERS 为**该 PR 自己**解锁（CODEOWNERS 取自**目标分支**）。

**5. 作者的 classic PAT 只有 `repo` + `workflow`，没有 `read:org`**
- 触发：用 `gh pr edit` 改 PR 正文 → 报 `Your token has not been granted the required scopes ... 'read:org'` 且**静默不更新**。
- **必须**：改 PR 正文用 REST：`jq -Rs '{body:.}' <文件> | gh api -X PATCH repos/$REPO/pulls/$N --input -`。
- **必须**：写后**回读校验**（`deliver.sh` 已封装）。

**6. 推送必须清掉本地 credential helper**
- 触发：直接 `git push`。
- **必须**：`git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin <branch>`。
- **违反后果**：macOS 钥匙串缓存的主身份凭据优先命中，作者身份推送**静默**变成主身份推送。

**7. macOS 自带 bash 是 3.2**
- 触发：写 bash4 语法 / `$VAR` 后紧跟中文 / BSD `sed` 用扩展正则不加 `-E`。
- **禁止**：`mapfile`、`readarray`、`declare -A`、`${var,,}`。
- **必须**：多字节字符前写 `${VAR}`（否则 `unbound variable`）；扩展正则用 `sed -E`。

**8. `blockedBy` 不会因对方关闭而自动清除**
- 触发：判定"是否真被阻塞"。
- **必须**：看 blocker 的 `state`（`start.sh` 已按 `state=OPEN` 判定）。

**9. squash 合并后 `git branch -d` 必然拒绝**
- 触发：原始提交不在 `main` 上时用 `-d`。
- **必须**：**先**验证 PR=MERGED、留锚点，**再** `-D`。
- **禁止**：无条件 `-D`。

**10. 状态迁移的判据是「HTTP 层单请求」，不是「一次 CLI 调用」**
- 触发：改回 `gh issue edit` 或多次写调用。
- **必须**：带标签 → 带标签的迁移只有**一条** HTTP 写请求 —— REST `PUT /repos/{owner}/{repo}/issues/{n}/labels`（整份替换）。
- **必须**：实现只放在一处：`status.sh` 的 `STATUS_LABELS_PUT` 标记区（读 → 改 → 写 → 读回校验）。
- **禁止**：`gh issue edit`（HTTP 层是 add/remove 两个**并发** mutation，中间态可能是 0 个或 2 个 `status/*`）。
- **违反后果**：`policy/branch-name` 对 0 或 2 个状态标签都判失败，失败的 SHA **不可逆**（陷阱 1）。
- **必须**：载荷带上读到的**全部非 `status/*` 标签**（`type/*`、`role/*` …）。
- **禁止**：整份替换只发 `status/*`（会**静默删掉**别人的标签）。
- **必须**：写后**读回校验**一次；非 `status/*` 集合不一致 → **报告并退出、不重试覆盖**。
- 三类迁移的载荷：带标签→带标签 = 非 `status/*` + 目标标签；→ `backlog` = 非 `status/*`。
- 三类迁移的载荷：→ `done`/`canceled` = 非 `status/*`，**先**整份替换、**后** `gh issue close`。
- **判据**（常驻 `ci/test`，不新增必需检查）：stub `gh` 跑**真实** `status.sh`。
- 断言：非终态迁移**恰好 1 次**标签写请求（且 0 次 `gh issue edit`），载荷含全部非 `status/*` 标签。
- **判据**（反向样本）：改回两次写请求、或载荷漏带 `type/*` → 该断言**必须失败**。

**11. tab 当字段分隔符会静默吞掉空字段**
- 触发：`IFS="$(printf '\t')" read -r a b c` 遇到连续 tab（tab 属 IFS 空白，连续空白只算一个分隔符）。
- **必须**：脚本内部的记录分隔用**非空白字符**（本仓库用 `|`）或给空值写占位符。
- **判据**：这类差别**必须**能用反向样本抓到。

**12. Issue 表单不会打标签，标签也没有清单**
- 触发：`bug.yml` 的「轨道」下拉选「线上故障」——它**不会**给 Issue 打 `type/hotfix`，而 `start.sh` 靠 `type/*` 推导分支类型。
- **必须**：线上故障用 `scripts/start.sh <issue#> --type hotfix --as author`，或先手动加 `type/hotfix` 标签。
- **违反后果**：热修**静默**退化成 `fix/`。
- **判据**：机器消费的标签由 `preflight.sh` 与 `ci/test` 用同一判据 `LABEL_ASSERT` 断言存在。
- **判据**：`ci/test` 里**必须**保留反向样本（删掉 `type/hotfix` 后断言必须失败）。

**13. 凭据隔离的能力边界：文件隔离只是提高门槛，不是防线本身**
- **禁止**：宣称"作者取不到评审凭据"或任何等价说法。
- 它提供：工作区边界（凭据落在仓库根内 → `review.sh` 报错退出、`preflight.sh` 记 `[FAIL]`）。
- 它提供：杜绝提交/泄露（不会被 `git add`、不撞 `ci/test` 的凭据扫描）。
- 它**不提供**：同一 OS 用户下两个凭据文件之间的身份隔离。
- 三身份分离的**强制点①**：平台 —— GitHub 拒绝自我批准（`Review Can not approve your own pull request`）
  + 规则集 `require_code_owner_review` / `require_last_push_approval`。
- 三身份分离的**强制点②**：契约 —— [../SKILL.md](../SKILL.md)「禁止」一节（作者不得读取其他身份凭据）。

## 5. 明确不做（边界）

**何时用本小节**：有人要求一个看起来"顺手"的能力时——先查这里是不是已声明不做。

不做「装到别人仓库」（无安装器/卸载器）｜不做 Projects｜不做度量报表｜不做跨模型评审留痕｜不做能力开关｜不做共享库（每个脚本自包含）。
**不引入第二套规范文档**：流程只在仓库里 —— `SKILL.md` + `references/**` + `.github/**` + `scripts/**` 就是全部权威。
