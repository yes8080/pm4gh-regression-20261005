# identity — 三身份、凭据与隔离判据

> **何时读**：首次开通身份凭据时；或 `preflight.sh` / `review.sh` 报身份、凭据、权限错误时。其余时间不必读。

## 三身份（平台强制；作者 ≠ 评审 ≠ 合并）

| 角色 | 账号 | 凭据（**必须在工作区之外**） | 职责 |
|---|---|---|---|
| 作者 | `@yes8080-dev-bot` | `$HOME/.config/pm4gh/developer.pat`（scope `repo, workflow`） | 拆片 + 建 Issue（**作者身份**）、建分支、提交、推送、开 PR、返修、`abort.sh` —— **只加** `--as author` |
| 评审 | `@yes8080-reviewer-bot` | `$HOME/.config/pm4gh/reviewer.pat`（scope `repo`） | `review.sh <pr#> approve\|request-changes` —— **不加** `--as`，**不得合并** |
| 合并 | `@yes8080` | 本机 `gh auth login` 登录态（无凭据文件） | `gh pr merge --squash`、改仓库设置、`closeout.sh` |

- **必须**：`start.sh` / `deliver.sh` / `abort.sh` 的 `--as` 只接受 `author`（作者身份不可被绕过）；`scripts/status.sh` 的**写迁移必须显式** `--as author|reviewer|dispatcher`，用**对应身份**的凭据执行 —— 审计归属 = **做事的人**，不是"谁的环境变量在场"（缺 `--as` → fail-closed 拒绝）。**禁止**用 `start.sh` / `deliver.sh` / `abort.sh` 把作者切成 dispatcher。
- **禁止**：读取其他身份的凭据内容；打印或提交任何凭据。
- **必须**：两份凭据都放**工作区之外**；工作区内出现 `*.pat` → `preflight.sh` 记 `[FAIL]`。

## 安装（仓库根目录就是 skill 包）

```bash
# 在**本仓库根目录**执行；$(git rev-parse --show-toplevel) = 本仓库根（skill 包根），不写死绝对路径
# 主推：.agents/skills 是跨客户端约定
mkdir -p ~/.agents/skills && ln -s "$(git rev-parse --show-toplevel)" ~/.agents/skills/pm4gh
# 兼容（部分客户端扫这里）：
mkdir -p ~/.claude/skills && ln -s "$(git rev-parse --show-toplevel)" ~/.claude/skills/pm4gh
```

- skill 安装位置与凭据位置**解耦**：skill 可是项目内目录或用户级符号链接，凭据**默认**在 `$HOME/.config/pm4gh/*.pat`（可用 `DEVELOPER_PAT_FILE` / `REVIEWER_PAT_FILE` 覆盖，见下）。
- 装成**克隆副本**也可以，**只要仓库根不在 `$HOME/.config/pm4gh` 之内** —— 凭据就仍在工作区之外。

## 开通凭据（由 PM / dispatcher 在**工作区之外**执行）

```bash
mkdir -p "$HOME/.config/pm4gh" && chmod 700 "$HOME/.config/pm4gh"
# 在 GitHub → Settings → Developer settings 生成 classic PAT：
#   作者 scope = repo, workflow；评审 scope = repo
printf '%s\n' '<作者 PAT>' > "$HOME/.config/pm4gh/developer.pat"
printf '%s\n' '<评审 PAT>' > "$HOME/.config/pm4gh/reviewer.pat"
chmod 600 "$HOME/.config/pm4gh/developer.pat" "$HOME/.config/pm4gh/reviewer.pat"
```

- **可选**：评审凭据放别的**工作区外**路径 → `REVIEWER_PAT_FILE=/工作区外/路径 scripts/review.sh <pr#> approve --body-file <文件>`。

## 隔离判据（唯一判据，两处逐字一致）

- **`review.sh`（W6）**：把 `REVIEWER_PAT_FILE` 解析成绝对路径（`cd … && pwd -P`，解析符号链接），落在仓库根之内 → **拒绝执行**（退出码 `1`）；**不读文件内容**，只判位置。
- **`preflight.sh`（W0）**：断言工作区内不存在任何 `*.pat`（`find . -name '*.pat'`）；作者凭据另查权限 `600` 与"未被 git 跟踪"。
- **机械同步**：上面两段判据的文本由 `ci/test` 断言**逐字一致**（`WORKSPACE_ASSERT` 标记区），并带反向样本（改成永不命中 → 断言必须失败）。只改一处 = 两套实现。

## 隔离的能力边界（**不要过度宣称**）

- **禁止**宣称"作者取不到评审凭据"之类的说法。
- 文件隔离**提供**：工作区边界（仓库根内的凭据被 `review.sh` 拒绝、被 `preflight.sh` 记 `[FAIL]`）；杜绝入库 / 泄露（不会被 `git add`，不撞 `ci/test` 的凭据扫描）。
- 文件隔离**不提供**：同一 OS 用户下两个凭据文件之间的身份隔离。
- 三身份分离的**强制点①**：平台 —— GitHub 拒绝自我批准（`Review Can not approve your own pull request`）+ 规则集 `require_code_owner_review` / `require_last_push_approval`。
- 三身份分离的**强制点②**：契约 —— 本文件与 [../SKILL.md](../SKILL.md) 的"不得读取其他身份凭据、不得自批"。
