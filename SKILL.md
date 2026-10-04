---
name: pm4gh
version: 1.0.0
description: "多 agent 用 GitHub 跑开发闭环：认领 Issue → 开工 → 交付 PR → 独立评审 → squash 合并 → 收尾。当你要在本仓库（yes8080/pm4gh）接手、推进或评审任何一个 Issue/PR 时使用。不负责：其他仓库的安装与治理、Projects、度量报表、跨模型评审留痕、能力开关。"
metadata:
  requires:
    bins: ["git", "gh", "jq"]
---

# pm4gh — 多 agent + GitHub 开发闭环

**本仓库只做两件事：多 agent + GitHub 工作流。** 状态只存在 GitHub（`status/*` 标签 + Issue 开关）：没有本地状态文件、没有安装器、没有度量报表。
**细节权威 = [references/workflow.md](references/workflow.md)**（两张表、W0..W8 细则、DoD、已知陷阱）；冲突时**以平台实际行为为准**。

## 0. 安装（本仓库根目录就是 skill 包）

```bash
ln -s /Users/ws/code/pm4gh ~/.claude/skills/pm4gh
```

凭据固定放 `$HOME/.config/pm4gh/developer.pat` / `$HOME/.config/pm4gh/reviewer.pat`。
若把仓库装到别处（克隆副本），**只要不在 `$HOME/.config/pm4gh` 之内**，凭据仍在仓库之外。

## 1. 身份（平台强制；作者 ≠ 评审 ≠ 合并）

| 角色 | 账号 | 凭据（**必须在工作区之外**） | 干什么 |
|---|---|---|---|
| 作者 | `@yes8080-dev-bot` | `$HOME/.config/pm4gh/developer.pat`（`repo, workflow`） | `start.sh` / `deliver.sh` / `abort.sh` —— 只接受 `--as author` |
| 评审 | `@yes8080-reviewer-bot` | `$HOME/.config/pm4gh/reviewer.pat`（`repo`） | `review.sh <pr#> approve\|request-changes` —— **不加** `--as`，不得合并 |
| 合并 | `@yes8080` | 本机 `gh auth login` 登录态 | `gh pr merge --squash`、改仓库设置、`closeout.sh` |

## 2. 闭环（顺序只有 W0..W8；每步「命令 → 判据」）

| 步 | 命令 | 判据（全过才进下一步） |
|---|---|---|
| W0 预检 | `scripts/preflight.sh` | 全 `[ OK ]`；任一 `[FAIL]` → 贴原文报 dispatcher，**禁止**"先干着看" |
| W1 领片 | `gh issue list --state open --label status/ready --limit 20 --json number,title,labels` | DoR 五项齐备（价值 / 可判定验收标准 / 边界 / 依赖 / 规模）才 `scripts/status.sh <n> ready` |
| W2 开工 | `scripts/start.sh <issue#> --as author`（线上故障加 `--type hotfix`） | 分支 `<type>/<issue#>-<slug>` 已建并绑定 Issue；状态 `in-progress` |
| W3 实现 | `bash -n scripts/*.sh`；提交 `git -c user.name="yes8080-dev-bot" -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" commit -F <文件>` | 工作区干净（`deliver.sh` 会拦）；提交者身份 = 作者 |
| W4 交付 | `scripts/deliver.sh <issue#> --prepare --as author` → 填六段 → `scripts/deliver.sh <issue#> --as author` | 正文含 `Closes #N` + `## 1.`..`## 6.`；状态 `in-review` |
| W5 检查 | `gh pr checks <pr#> --required` | `ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template` 全 `pass` |
| W6 评审 | `scripts/review.sh <pr#> approve --body-file review.md`（评审身份） | `reviewDecision=APPROVED`；打回 → 状态 `in-progress`，**同一分支**返修 |
| W7 合并收尾 | `gh pr merge <pr#> --squash --delete-branch` → `scripts/closeout.sh <pr#>` | 只有 dispatcher 能合并；closeout 五项全过 |
| W8 取消 | `scripts/abort.sh <issue#>` | 只在「不做」时用；删分支前**必须**能证明内容不会丢 |

分支类型 `type ∈ {slice,fix,hotfix,spike,chore}`；PR 标题 = Issue 标题，无覆盖开关。

## 3. 状态机（6 状态；唯一权威 = `scripts/status.sh` 的 `TRANSITIONS`，逐字表见 references/workflow.md §1）

| 状态 | 载体 / 含义 | 合法出边 |
|---|---|---|
| `backlog` | Issue OPEN 且无 `status/*` | `ready` `in-progress` `done` `canceled` |
| `ready` | `status/ready` | `in-progress` `backlog` `canceled` |
| `in-progress` | `status/in-progress` | `in-review` `ready` `backlog` `canceled` |
| `in-review` | `status/in-review`（评审中 / 已批准待合并） | `in-progress` `done` `backlog` `canceled` |
| `done` | Issue CLOSED + `state_reason=completed`，无 `status/*` | 终态，无出边 |
| `canceled` | Issue CLOSED + `state_reason=not_planned`，无 `status/*` | 终态，无出边 |

迁移只能走 `scripts/status.sh <issue#> <state>`；动手前用只读的 `scripts/status.sh --check-transition <from> <to>` 判定（退出码 0 合法 / 1 非法）。**判据是「HTTP 层单请求」**（REST `PUT …/labels` 整份替换）—— **禁止**改回 `gh issue edit`。表外迁移一律失败，**没有跳过开关**。

## 4. 必须

1. 所有改动经 PR：分支 → PR → 5 个必需检查 → 独立评审 → dispatcher 合并；**一个切片 = 一个 Issue = 一个分支 = 一个 PR**，同时只允许一个 `status/in-progress`
2. 留**可核对**证据：命令、输出、检查名、运行链接；**禁止**"已测试通过"这类无证据断言
3. 状态**只能**通过 `scripts/status.sh` 迁移；迁移前先跑 `--check-transition`
4. 提交用 `-F <文件>` + 作者身份（`--as author` 只切 `gh` 身份，不改 git 身份）；合并后**必须**跑 `scripts/closeout.sh <pr#>`
5. 关键节点在 Issue 留**简短**进度评论（分支已建 / 改动完成 / 遇到阻塞）
6. 脚本自包含、兼容 macOS bash 3.2：禁 `mapfile`/`readarray`/`declare -A`/`${var,,}`；`$VAR` 后紧跟中文必须写 `${VAR}`

## 5. 禁止

| 禁止 | 后果 |
|---|---|
| 直推 / 强推 `main`、删 `main`；`gh pr merge --admin` 或任何绕过门禁的手段 | 规则集拒绝；bypass 名单为空 |
| 改 5 个必需检查的 job `name:`，或给必需检查工作流加 `paths`/`branches` 过滤 | 所有 PR 永久 pending |
| 改线上规则集或 `main-protection.json` | 属 dispatcher 权限；写错会让所有 PR 卡住 |
| 读取其他身份的凭据（作者读 `reviewer.pat` / `main.pat`）、打印 / 提交任何凭据 | 越过身份；`ci/test` 扫描凭据 |
| 绕过 `status.sh` 改状态标签、把状态写进本地文件、自建流程（TODO 文件 / 自造状态机 / 分支策略 / 共享库） | 状态分裂；流程只在仓库里 |
| 自批（作者批准自己的 PR）、作者代跑 W7 合并、评审身份合并 | 平台直接拒绝 |
| 引用或重建 `src/*`、`size/*` 标签，引用 `status/rework` | 这些标签在本仓库已删除，不存在 |

## 6. 异常处理

| 情况 | 正确反应 |
|---|---|
| `preflight.sh` 有 `[FAIL]` | 停下，把失败项**原文**报告 dispatcher |
| 必需检查永久 pending | 核对 job `name` 是否被改名、工作流是否被 `paths` 过滤（references/workflow.md §4 陷阱 2） |
| `mergeStateStatus=BLOCKED` 但 `reviewDecision=APPROVED` | 该 SHA 上留有**失败结论**的必需检查（不可逆）→ 报告，不要绕过 |
| 发现流程缺陷 | 开 Bug Issue（复现 / 期望 / 实际 / 影响版本 / 缓解），**禁止**顺手改掉 |
| 发现需求歧义 | 停下请求澄清，**禁止**自行扩大范围 |

完成标准（DoD）与全部陷阱：**[references/workflow.md](references/workflow.md)** §3、§4。
