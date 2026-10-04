# 可移植治理套件（toolkit）

> **一页讲清：装什么、改什么、怎么撤。**
> 本目录是 Issue #46（E2-S1）的交付物：**归属清单 + 安装器的 `--dry-run` / `--check`**。
> 设计依据见 `docs/PLAYBOOK.md`（流程）与 `docs/GOVERNANCE.md`（规则）。

## 1. 它是什么

把本仓库已经收敛的治理资产打包成**一份清单（`manifest.json`）+ 一个安装器（`install.sh`）**，
可以装进**任意已有仓库**，并且**随时能撤干净**（卸载能力见 S2 的 `eject.sh`）。

- **唯一归属依据**：`manifest.json` 登记本套件创建/修改的每一个对象；未登记却做了修改 = 缺陷。
- **零新增运行时依赖**：只用 `bash`（3.2 兼容）/ `git` / `gh` / `jq` 与 POSIX 自带命令。
- **不接管用户既有配置**：对象已存在但不是本套件创建 → **不覆盖、不接管，只报告**。

## 2. 受管对象（install/shape）

| 类别 | 内容 | 数量 |
|---|---|---|
| `files` | `.github/labels.yml`、`.github/rulesets/main-protection.json`、`.github/authorized-identities.txt`、`.github/PULL_REQUEST_TEMPLATE.md`、`.github/ISSUE_TEMPLATE/*.yml`（6） | 10 |
| `labels` | 类型/角色/领域/来源/优先级/规模/状态/风险 标签（值取自 `payload/labels.yml`） | 35 |
| `rulesets` | `main-protection`（目标 `~DEFAULT_BRANCH`、必需检查 5 项、审批/CODEOWNERS/仅 squash 等） | 1 |
| `workflows` | `required-checks.yml`（`ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template`）与 `acceptance-check.yml`（`qa/acceptance`，非必需审计检查） | 2 |
| `codeowners` | `CODEOWNERS` 必需行（每行都含**非作者** owner，避免 `require_code_owner_review` 死锁） | 6 |
| `collaborators` | 作者身份、独立评审/验收身份（`permission=push`，**持久权限**） | 2 |

`payload/**` 是策略正文；其中身份/仓库相关内容写成占位符（`@@OWNER@@`、`@@OWNER_MENTION@@`、
`@@REVIEWER_ACCOUNT@@`、`@@REVIEWER_MENTION@@`、`@@AUTHOR_ACCOUNT@@`、`@@REPO@@`、`@@DEFAULT_BRANCH@@`），
安装时按目标仓库替换 —— **套件内没有任何硬编码的仓库名或账号**
（自检 `toolkit/tests/self-test.sh` 的 T0 会强制这一点）。

## 3. 怎么用

```bash
# ① 只预告，零写入（默认模式）
toolkit/install.sh --dry-run

# ② 只校验：比对线上实况与 manifest 期望，漂移只报告（退出码 1 = 有漂移）
toolkit/install.sh --check

# ③ 真正安装（幂等；重复执行是 no-op）
toolkit/install.sh --apply
```

参数（全部可参数化，与 `manifest.json` 的 `parameters` 段一一对应）：

| 参数 | 环境变量 | 默认来源 |
|---|---|---|
| `--repo OWNER/NAME` | `REPO` | `gh repo view`（当前仓库） |
| `--default-branch NAME` | `DEFAULT_BRANCH` | `gh repo view` 的 `defaultBranchRef` |
| `--owner ACCOUNT` | `OWNER` | `REPO` 的 owner 部分 |
| `--author-account ACCOUNT` | `AUTHOR_ACCOUNT` | 读凭据文件对应身份（默认 `.secrets/developer.pat`） |
| `--reviewer-account ACCOUNT` | `REVIEWER_ACCOUNT` | 读凭据文件对应身份（默认 `.secrets/reviewer.pat`） |
| `--root DIR` | — | 套件目录的上一级（宿主仓库根） |
| `--kit-dir DIR` / `--manifest FILE` | — | 脚本所在目录 / `<kit-dir>/manifest.json` |

**凭据**：脚本只读凭据文件内容用于确认身份，**从不打印、从不落盘**。
`--apply` 创建规则集与协作者需要 **admin 权限**（作者/评审身份只有 write，属预期：这类操作由 dispatcher 执行）。

## 4. 三种状态的幂等语义（planned → observed → owned）

| 状态 | 含义 | 谁来定 |
|---|---|---|
| `planned` | `manifest.json` 里声明的期望 | 清单（人写的） |
| `observed` | **本次运行现读的线上实况** | 每次运行重新探测；**绝不用上一次的记账代替观测** |
| `owned` | 本套件创建或明确接管 | `--apply` **写前落账**（`intent=create`）+ 成功后回读确认 |

- **重试语义**：上一次命令报错、但对象其实已创建 → 记账里留有 `create` 意图，且本次实况存在
  → 仍判 `owned=true`，不会被误当成"用户既有对象"而漏记（失败案例库 D6 的直接教训）。
- **重复 install 是 no-op**：所有对象都命中"已存在且一致" → 0 创建 / 0 更新 / 0 写入。
- **冲突不静默**：`--apply` 遇到"非本套件创建且与期望不一致"的对象会跳过它并以退出码 1 结束，
  等人工决定（改清单、或手工让既有对象就位），**不会**替用户改配置。

退出码：`0` 无漂移/安装成功；`1` 有漂移或冲突；`2` 参数或环境错误。

## 5. 怎么撤

- **归属**：只有 `manifest.json` 的 `ledger` 里 `owned=true` **且未漂移**的对象才允许被移除。
- **S1 现状**：`eject.sh` 属 S2（`[E2-S2]`）；本切片只产出清单与 `--dry-run/--check`，
  `--dry-run/--check` **没有任何写入路径**（可用 `--check` 前后 `git status` 与清单校验和自证）。
- **本仓库（宿主）**：治理资产早于套件存在，因此 `--check` 会把它们全部视为
  `pre_existing=true, owned=false` —— 换句话说，**未来 eject 在本仓库不会删任何东西**。
- **协作者是持久权限**：S2 的卸载必须询问式处理（默认保留），不得静默撤销。

## 6. 自检与验证

```bash
# 离线自检（不联网、不碰任何真实仓库）：55 条断言
bash toolkit/tests/self-test.sh

# 在宿主仓库上核对"与现状一致"（只读）
toolkit/install.sh --check
```

`toolkit/tests/` 下是自检装置：`stub-gh.sh` 是一个 gh 假实现（模拟标签/规则集/协作者），
用来验证"创建 / 不覆盖 / 重复执行为 no-op / 报错后仍能正确归属"这些**不能拿真实仓库做实验**的语义。

## 7. 已知边界（S1 有意不做）

- 不实现卸载（`eject.sh`）、tombstone、漂移保护 → S2。
- 不实现策略开关（B9/B11/B12/B13）与跨模型评审（B22）→ S4/S5。
- 不管理目标仓库的业务代码与业务 CI；不引入 Projects。
- 文件类对象的比对基准是**宿主仓库工作区**（`--root` 下的文件），不是远端默认分支的副本。
