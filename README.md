# pm4gh

**本项目只做两件事：多 agent + GitHub 工作流。**

- **多 agent**：作者 ≠ 评审 ≠ 合并。三者身份独立，**由 GitHub 平台强制**（不是靠自觉）
- **GitHub 工作流**：Issue → 分支 → PR → 必需检查 → 独立评审 → squash 合并 → 收尾

状态只存在 GitHub（`status/*` 标签 + Issue 开关状态）：没有本地状态文件、没有安装器、没有度量报表、
没有"可移植治理套件"。

## 权威在哪（同一规则只写一处，本文件只做门面与导航）

| 想知道 | 读 |
|---|---|
| 三身份（谁、凭据、平台怎么强制） | [docs/WORKFLOW.md §0](docs/WORKFLOW.md) |
| 状态机（6 个状态、15 条边）与状态载体 | [docs/WORKFLOW.md §1](docs/WORKFLOW.md) |
| 闭环 W0..W8（每步的命令、前置条件、判据） | [docs/WORKFLOW.md §2](docs/WORKFLOW.md) |
| 什么算做完（DoD） | [docs/WORKFLOW.md §3](docs/WORKFLOW.md) |
| 已知陷阱（均有原始证据） | [docs/WORKFLOW.md §4](docs/WORKFLOW.md) |
| 必须做 / 禁止做（接手契约） | [AGENTS.md](AGENTS.md) |

**闭环（六步）**：`preflight.sh` → `start.sh <issue#> --as author` → `deliver.sh <issue#> --as author`
→ `review.sh <pr#> approve`（评审身份）→ `gh pr merge --squash --delete-branch`（只有 dispatcher）→ `closeout.sh <pr#>`；
异常路径（PR 关闭不合并 / 作者放弃 / Issue 取消）走 `scripts/abort.sh <issue#>`，判据见 [WORKFLOW §2](docs/WORKFLOW.md)。

## 脚本（全部自包含，无共享库）

| 脚本 | 作用 | 关键不变量 |
|---|---|---|
| `preflight.sh` | 开工前预检 | 三身份互不相同；线上规则集与仓库内定义一致 |
| `start.sh` | Issue → 分支 | 分支名匹配 `^(slice\|fix\|hotfix\|spike\|chore)/\d+-[a-z0-9-]+$`；身份只有 `--as author` |
| `status.sh` | **唯一**状态迁移入口 | 开放 Issue 恰好 0 或 1 个 `status/*`；转换表外一律拒绝（**没有跳过开关**） |
| `deliver.sh` | 推送 + 开/更新 PR | 正文含 `Closes #N` + 六段；身份只有 `--as author` |
| `review.sh` | 独立评审 | 评审身份 ≠ 作者身份 |
| `closeout.sh` | 合并后核验 | 写分支 tip SHA + PR head SHA 到 Issue 再删分支 |
| `abort.sh` | 异常路径出口（PR 关闭不合并 / 作者放弃 / Issue 已取消） | 不能证明「内容不会丢」就**拒绝删除**；状态只走 `status.sh`；先留可恢复锚点 |

> 每个脚本自带所需的身份/工具函数，不依赖共享库 —— 单文件可读、可独立复制。**不要引入共享库。**

## 铁律（违反会让 PR 永久卡住）

- **5 个必需检查的 job `name:` 一字不能改**：`ci/lint`、`ci/test`、`policy/linked-issue`、
  `policy/branch-name`、`policy/template`。context = 工作流里 job 的 `name:`（不是文件名）。
- **必需检查的工作流不得配 `paths`/`branches` 过滤**，也不得靠 `issue_comment` 触发：被跳过 = 永久 pending。
- **不要改线上规则集**（仓库设置属 dispatcher 权限）。认为必须改 → 停下报告。
- 所有改动经 PR；不直推 `main`；不用 `--admin`。
- 脚本必须兼容 macOS 自带 bash 3.2：禁 `mapfile`/`readarray`/`declare -A`/`${var,,}`；
  `$VAR` 后紧跟中文必须写 `${VAR}`。
