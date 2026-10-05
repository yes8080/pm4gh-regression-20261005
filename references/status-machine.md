# status-machine — 状态机与状态迁移（唯一表权威）

> **何时读**：任何一次状态迁移之前。查 `from` 的合法出边与触发者，再敲命令。

## 规则

- 状态集 **6 个**：`backlog | ready | in-progress | in-review | done | canceled`。
- **必须**：迁移**只能**走 `scripts/status.sh <n> <state> --as author|reviewer|dispatcher`；**禁止**直接改标签、**禁止**把状态写进本地文件。
- **必须**：任何不可逆副作用（建分支 / 推送 / 建 PR）**之前**先跑只读判定 `scripts/status.sh --check-transition <from> <to>` → 退出码 `0` 合法 / `1` 非法 / `2` 用法错。
- **判据**：`scripts/status.sh <n> <state> --as <身份>` 退出码 `0` 成功 / `1` 校验或迁移失败 / `2` 参数错；**写迁移缺 `--as` → fail-closed 拒绝**（只读模式 `--check` / `--check-transition` / `--check-cross` 不需要 `--as`）。
- **禁止**：表外 `from → to`（含终态出边、跨级跳跃）—— 一律失败，**没有跳过开关**。
- **必须**：要例外就开 Issue 补一条边，同时改 `scripts/status.sh` 的 `TRANSITIONS` 与本表（`ci/test` 断言两处逐字一致）。
- `in-review` = 「评审中 / 已批准待合并」，没有单独的「验收」状态；「被打回」**不设独立状态** = `in-review → in-progress`（平台另有 `reviewDecision=CHANGES_REQUESTED`）。
- `from == to`（同状态）视为**幂等合法**：`status.sh` 直接返回 `0`，不改任何东西。

### 状态迁移表（**唯一表权威**：6 个状态、15 条边；与 `scripts/status.sh` 的 `TRANSITIONS` 由 `ci/test` 断言**逐字一致**）

<!-- TRANSITIONS:BEGIN（机器可读；与 scripts/status.sh 的 TRANSITIONS 逐字一致，由 ci/test 断言；首列 = 状态集，其余反引号 token = 出边） -->

| from | to | 触发者 | 命令/事件 | 类型 |
|---|---|---|---|---|
`backlog` | `ready` | 人/PM | W1 DoR 五项齐备 | 正常
`backlog` | `in-progress` | dev-bot | W2 start.sh 直接开工（不假定 Issue 在 backlog） | 正常
`backlog` | `done` | 人/PM·dispatcher | 非切片 Issue（Epic / Audit / 提案）收尾：待办项已**全部**关闭 → `scripts/status.sh <n> done --as dispatcher` | 终态
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

（说明）转换表**只用表**：一行一条边，可 grep / awk 校验；**禁止**画图。
`类型`：`正常` = 主路径推进；`异常` = 回退 / 打回 / 终止。
表内 `done` / `canceled` 两行是**终态说明行**（无出边），不计入 15 条边；比对口径 = `TRANSITIONS` 里的 from→to 集合。

## `done` 的三层语义（`backlog → done` 的边界）

| 场景 | 合法路径 | 含义 |
|---|---|---|
| 切片（Issue → 分支 → PR） | `in-review → done` | 已经过评审并合并、收尾完成（W7 + `closeout.sh`） |
| 非切片（Epic / Audit / 提案） | `backlog → done` | 该 Issue 的待办项已全部关闭（它自己不产出 PR） |
| 不做（任意非终态） | `→ canceled` | `state_reason=not_planned` —— 与 `done` 的区别正是 `state_reason` |

- **必须**：切片要进 `done`，`in-review` 是**必经**状态；**禁止**用 `backlog → done` 替代 `in-review → done`。
- **判据**（`backlog → done` 前逐项确认，三条全成立）：① 不是切片（切片走 W2..W7）② 无未关闭的待办子项 ③ 无关联 PR。

## 状态载体与体检

- 载体：`ready` / `in-progress` / `in-review` = 对应 `status/*` 标签（**互斥**）；`backlog` = Issue OPEN 且无 `status/*`；`done` / `canceled` = Issue CLOSED（`state_reason=completed` / `not planned`）**且**无任何 `status/*` 标签。
- **必须**：`scripts/status.sh --check`（扫全部开放 Issue，每个必须 0 或 1 个 `status/*`）退出码 `0`；`ci/test` 每次 PR 跑同一不变量。

## 交叉体检（只读，Issue ↔ PR）— `scripts/status.sh --check-cross`

**何时用**：发现「Issue 已 `in-review` 而关联 PR 被关闭」这类不一致时（`--check`、`ci/test`、`policy/*` 都只读 Issue，兜不住这类冲突）。

| 规则 | 判据 |
|---|---|
| R1 | Issue 为 `in-review`，但关联 PR 已 `CLOSED`（未合并） |
| R2 | Issue 为 `done`，但关联 PR 未合并（仍开放 / 已关闭未合并） |
| R3 | Issue 为 `in-review`，但**没有任何开放 PR** |
| R4 | 有开放 PR，但 Issue 无任何 `status/*`（Backlog） |

- **判据**：退出码 `0` = 四条全未命中；`1` = 存在冲突（逐条打印规则、Issue/PR 号与关联方式）；`2` = 查询失败 / 用法错。
- 「关联」只认两种可判定证据：PR 的 `closingIssuesReferences`，或分支名 `<type>/<issue#>-<slug>`。
- **禁止**猜测两者都没有的 PR —— 如实标注「无法判定」并列出，不计入冲突。
- **禁止**把本命令当成写操作 —— 它零副作用（只发 GET、只写临时目录）。

## 单请求 PUT（迁移的原子性判据）

- **判据是「HTTP 层单请求」**，不是「一次 CLI 调用」：带标签 → 带标签的迁移只有**一条**写请求（REST `PUT …/labels` 整份替换）。**禁止**改回 `gh issue edit`。
- 三类载荷、读回校验、反向样本见 [traps.md](traps.md) 陷阱 10；实现只在 `scripts/status.sh` 的 `STATUS_LABELS_PUT` 标记区，由 `ci/test` 常驻断言。

## 标签族定位（**唯一一处**声明）

| 标签族 | 定位 |
|---|---|
| `status/*` | **消费者**：`status.sh`（唯一迁移入口）/ `start.sh` / `deliver.sh` / `abort.sh` / `closeout.sh` / `ci/test` |
| `type/*` | **消费者**（仅 `bug` / `hotfix` / `spike` / `chore`）：`start.sh` 据此推导分支类型；`task` / `feature` 无消费者 → 人类元数据 |
| `prio/*`、`risk/*`、`role/*`、`area/*`、GitHub 默认标签 | **人类元数据（机器不读）**：只供人筛选 |
| `src/*`、`size/*` | **不存在**。**禁止**引用或重建；`status/rework` 同样**禁止**引用 |

- **判据**：机器消费的标签 + **Issue 表单预置的标签**（`.github/ISSUE_TEMPLATE/*.yml` 的 `labels:`）由 `preflight.sh`（W0）与 `ci/test`（每次 PR）用**同一段判据**（`LABEL_ASSERT`）断言存在，并带反向样本（手写项 `type/hotfix` 与模板解析项 `role/dev` 各一）。
- **必须**：新增**机器消费**标签（`status/*` / `type/*`）时同步三处 —— `preflight.sh` 的 `MACHINE_LABELS`、`ci/test` 的同一段副本、线上标签本身（由 dispatcher 加）；**Issue 表单预置标签**由判据**从模板解析**（不需要改判据文本），但线上仍必须先有该标签，否则用该表单建单直接失败。
