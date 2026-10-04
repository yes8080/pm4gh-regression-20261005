# pm4gh

**本项目只做两件事：多 agent + GitHub 工作流。**

- **多 agent**：作者 ≠ 评审 ≠ 合并。三者身份独立，**由 GitHub 平台强制**（不是靠自觉）
- **GitHub 工作流**：Issue → 分支 → PR → 必需检查 → 独立评审 → squash 合并 → 收尾

状态只存在 GitHub（`status/*` 标签 + Issue 开关状态）：没有本地状态文件、没有安装器、没有度量报表、
没有"可移植治理套件"。

## 三个身份

| 角色 | 账号 | 能做什么 | 凭据 |
|---|---|---|---|
| 作者 | `@yes8080-dev-bot` | 建分支、提交、推送、开 PR、返修 | `.secrets/developer.pat`（classic PAT，scope `repo, workflow`） |
| 评审 | `@yes8080-reviewer-bot` | `approve` / `request-changes`（**不得合并**） | `.secrets/reviewer.pat`（classic PAT，scope `repo`） |
| 合并 | `@yes8080`（dispatcher） | 只有它能 `gh pr merge --squash` | 本机 `gh auth login` 登录态 |

平台强制点：GitHub **禁止自我批准**；规则集要求 1 名**非作者**的 code owner 批准
（`.github/rulesets/main-protection.json` + `.github/CODEOWNERS`）。作者自己 approve 会被服务端拒绝。

## 闭环（六步，每步一条命令）

```bash
scripts/preflight.sh                                  # 1. 开工前预检（环境 / 三身份 / 规则集）
scripts/start.sh 77 --as author                        # 2. Issue → 分支 + status/in-progress
#    … 实现 …  用作者身份提交：git -c user.name=… -c user.email=… commit -F /tmp/msg.txt
scripts/deliver.sh 77 --prepare --as author            # 3a. 生成 PR 六段骨架
scripts/deliver.sh 77 --as author                      # 3b. 推送 + 开 PR + status/in-review
scripts/review.sh 12 approve --body-file review.md     # 4. 独立评审（reviewer 身份）
gh pr merge 12 --squash --delete-branch                # 5. 只有 dispatcher 能做这一步
scripts/closeout.sh 12                                 # 6. 五项核验 + 写可恢复锚点
```

「六步」= preflight → start → deliver → review → 合并 → closeout。

## 状态机（唯一源 = `status/*` 标签）

```
Backlog(无标签) → ready → in-progress → in-review → Done(PR 合并自动关单)
                                  ↘ rework（被打回，在同一分支继续提交）
```

- 迁移**只能**走 `scripts/status.sh <issue#> <state>`（`backlog|ready|in-progress|in-review|rework|done|canceled`）
- `scripts/status.sh --check` 扫描**全部开放 Issue**：每个必须恰好 0 或 1 个 `status/*` 标签（0 = Backlog）
- 关闭 Issue = 状态 Done/Canceled 的载体（`Closes #N` 由 squash 合并自动关单并清空标签）

## 30 秒上手

1. `scripts/preflight.sh` —— 任何一项失败就**停下报告**，不要"先干着看"
2. 读 `AGENTS.md`（契约：必须做/禁止做）与 `docs/WORKFLOW.md`（步骤、判据、已知陷阱）
3. `scripts/start.sh <issue#> --as author`，然后按上面六步走

## 脚本（全部自包含，无共享库）

| 脚本 | 作用 | 关键不变量 |
|---|---|---|
| `preflight.sh` | 开工前预检 | 三身份互不相同；线上规则集与仓库内定义一致 |
| `start.sh` | Issue → 分支 | 分支名必须匹配 `^(slice\|fix\|hotfix\|spike\|chore)/\d+-[a-z0-9-]+$` |
| `status.sh` | **唯一**状态迁移入口 | 开放 Issue 恰好 0 或 1 个 `status/*`；Done/Canceled 还要求无任何 `status/*` |
| `deliver.sh` | 推送 + 开/更新 PR | 正文含 `Closes #N` + 六段 |
| `review.sh` | 独立评审 | 评审身份 ≠ 作者身份 |
| `closeout.sh` | 合并后核验 | 写分支 tip SHA + PR head SHA 到 Issue 再删分支 |

> 每个脚本自带所需的身份/工具函数，不依赖共享库 —— 单文件可读、可独立复制。**不要引入共享库。**

## 铁律（违反会让 PR 永久卡住）

- **5 个必需检查的 job `name:` 一字不能改**：`ci/lint`、`ci/test`、`policy/linked-issue`、
  `policy/branch-name`、`policy/template`。context = 工作流里 job 的 `name:`（不是文件名）。
- **必需检查的工作流不得配 `paths`/`branches` 过滤**，也不得靠 `issue_comment` 触发：被跳过 = 永久 pending。
- **不要改线上规则集**（仓库设置属 dispatcher 权限）。认为必须改 → 停下报告。
- 所有改动经 PR；不直推 `main`；不用 `--admin`。
- 脚本必须兼容 macOS 自带 bash 3.2：禁 `mapfile`/`readarray`/`declare -A`/`${var,,}`；
  `$VAR` 后紧跟中文必须写 `${VAR}`。
