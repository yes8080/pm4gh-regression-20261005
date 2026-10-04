# 可移植治理套件（toolkit）

> **一页讲清：装什么、改什么、怎么撤。**
> 本目录是 Issue #46（E2-S1，安装与归属清单）与 Issue #47（E2-S2，干净卸载）的交付物：
> **归属清单 `manifest.json` + 安装器 `install.sh` + 卸载器 `eject.sh`**。
> 设计依据见 `docs/PLAYBOOK.md`（流程）与 `docs/GOVERNANCE.md`（规则）。

## 1. 它是什么

把本仓库已经收敛的治理资产打包成**一份清单（`manifest.json`）+ 一个安装器（`install.sh`）+ 一个卸载器（`eject.sh`）**，
可以装进**任意已有仓库**，并且**随时能撤干净**。

- **唯一归属依据**：`manifest.json` 登记本套件创建/修改的每一个对象；未登记却做了修改 = 缺陷。
- **零新增运行时依赖**：只用 `bash`（3.2 兼容）/ `git` / `gh` / `jq` 与 POSIX 自带命令。
- **不接管用户既有配置**：对象已存在但不是本套件创建 → **不覆盖、不接管，只报告**；
  卸载时同样**不动**这些对象，且"撤掉自己那些"必须先证明**未漂移**。
- **归属/漂移判定只有一份实现**：`install.sh` 与 `eject.sh` 共用 `toolkit/lib.sh`
  （若各写一份，就会出现"install 认为 owned、eject 认为不是"的静默不一致）。

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
toolkit/eject.sh                          # 卸载预告（默认也是 --dry-run）

# ② 只校验：比对线上实况与 manifest 期望，漂移只报告（退出码 1 = 有漂移）
toolkit/install.sh --check
toolkit/eject.sh --check                  # 核验"是否已回到装机前状态"

# ③ 真正安装 / 真正卸载（都幂等；都可中断续跑）
toolkit/install.sh --apply
toolkit/eject.sh --apply
toolkit/eject.sh --apply --force                   # 允许删除**已漂移**的 owned 对象（默认保留）
toolkit/eject.sh --apply --revoke-collaborators    # 显式撤销协作者（默认保留并提示手动命令）
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

## 5. 怎么撤（`eject.sh`，E2-S2）

**四条语义**（每一条都有离线自检覆盖，见 §6）：

| # | 语义 | 实现 |
|---|---|---|
| ① | **只删 owned 且未漂移** | 逐个受管对象比对"期望内容 vs 现读实况"：`owned=true`（或留有 `create` 意图，D6）且**未漂移**才删；`pre_existing`/非本套件对象**只报告、绝不删** |
| ② | **漂移默认保留** | 内容/颜色/参数/CODEOWNERS owner 与期望不一致 → `[保留]` 并计入小结，**需显式 `--force` 才删**（`--apply` 此时退出码 1 = 需人工决定） |
| ③ | **协作者询问式** | 持久权限：默认**保留** + 报告 + 打印手动撤销命令；只有显式 `--revoke-collaborators` 才撤销，**绝不静默撤销** |
| ④ | **tombstone（可中断可续跑）** | 任何不可逆动作**之前**先写 `<root>/.git/toolkit-eject-tombstone.json`（计划 + 装机前 baseline + 可恢复锚点）与 `…-record.md`（可选 `--record-issue N` 写入 Issue），并备份文件内容/规则集正文到 `…-backup/`；中断后**重跑即续跑**，续跑依据是**每次重新读线上实况**，不是上次运行的记账（D6），baseline 也沿用首次的、不重新打底 |

**删除顺序**（不可逆程度递增，最持久的放最后）：文件 → CODEOWNERS 行 → 标签 → 规则集 → 协作者。

**卸载后的核验**：`toolkit/eject.sh --check` 退出码 0 表示"与装机前一致"：
受管文件全消失、本套件创建的标签/规则集全消失、**用户原有对象一个不少**
（按 tombstone 的 baseline 比对 `.github` 下所有非受管文件、标签、规则集、协作者与 CODEOWNERS 原有行；
保留的协作者作为"持久权限例外"单独列出，不算失败但绝不静默）。
同一件事可用只读的 `toolkit/install.sh --check` **交叉印证前半部分**：卸载后它会把每个受管对象
（10 文件 + 35 标签 + 1 规则集 + 2 工作流 + 6 CODEOWNERS 行 = 54 条）逐条报成"缺失/漂移"，
即"受管文件全消失、本套件创建的对象全消失"。
但 **"用户原有对象一个不少"只能由 `eject.sh --check` 给出**：用户对象不在 manifest 里，
`install.sh --check` 自然不会列出它们 —— 这正是 `eject.sh` 要在卸载前把 baseline 存进 tombstone 的原因。

**退出码**（`eject.sh`）：`0` 完成/一致；`1` 有删除失败，或存在因漂移而保留、需人工决定的对象；`2` 参数或环境错误。
`--check` 的 baseline 比对需要 tombstone；没有 tombstone 时它只做 manifest 判定并**显式告警**"证据只有一半"。

**权限**：撤销规则集/协作者需要 **admin**（与 install 对称，这两类由 dispatcher 执行）；文件/标签用 write 即可。

**本仓库（宿主）**：治理资产早于套件存在，因此归属记账为空 ——
`eject.sh --dry-run` 会报告"0 删除、全部为装机前已存在"，**在本仓库不会删任何东西**。

## 6. 自检与验证

```bash
# 离线自检（不联网、不碰任何真实仓库）：154 条断言
bash toolkit/tests/self-test.sh

# 在宿主仓库上核对"与现状一致"（只读）
toolkit/install.sh --check
toolkit/eject.sh --check
```

**这条自检已接入 CI 门禁（Issue #57）**：必需检查 `ci/test` 中有一节
`toolkit 自检（install/eject 语义：存在即执行、缺失即失败）`，它真实执行本脚本，
并按契约处理两种边界：

- **失败即失败**：任何 `[FAIL]` → 该步骤非零退出 → `ci/test` 变红（不吞输出、不 `|| true`）；
- **缺失即失败**：`toolkit/tests/self-test.sh` 被删除或改名时**直接报错退出**，
  绝不当作"没找到就跳过"——否则覆盖面会被静默清零，门禁看起来仍是绿的。

同一节也同步写进了 `payload/workflows/required-checks.yml`，因此装到目标仓库的 CI 同样包含它
（两处内容除占位符外必须逐字一致）。

`toolkit/tests/` 下是自检装置：`stub-gh.sh` 是一个 gh 假实现（模拟标签/规则集/协作者，
含 `label delete` / `ruleset|collaborator DELETE` / `issue comment` 与故障、中断注入），
用来验证"创建 / 不覆盖 / 重复执行为 no-op / 报错后仍能正确归属 / 卸载只删 owned 且未漂移 /
漂移默认保留 / 中断可续跑 / 用户原有对象一个不少"这些**不能拿真实仓库做实验**的语义。

eject 的语义覆盖（Test 10–15）：`--dry-run` 零写入预告 → `--apply` 干净卸载 → `--check` 报"与装机前一致"；
漂移默认保留、`--force` 才删；`TOOLKIT_EJECT_ABORT_AFTER` 模拟进程中断后重跑收敛；
stub 注入删除失败后重跑收敛；装机前已存在（`pre_existing`）的对象绝不删；
未登记的用户对象（标签/规则集/协作者/.github 文件/CODEOWNERS 行）一个不少，
并带**反向样本**证明这些"全绿"不是空断言。

> `TOOLKIT_EJECT_ABORT_AFTER=<class>:<id>` 是**仅供自检**的中断接缝（完成该对象后 `exit 3`），生产不使用。

## 7. 已知边界

- 不实现策略开关（B9/B11/B12/B13）与跨模型评审（B22）→ S4/S5。
- 不管理目标仓库的业务代码与业务 CI；不引入 Projects。
- 文件类对象的比对基准是**宿主仓库工作区**（`--root` 下的文件），不是远端默认分支的副本。
- tombstone / 记录 / 备份落在**宿主仓库的 `.git/` 下**（`--tombstone` 可改路径）：
  它们是"卸载这台机器上的这次操作"的**事务日志与锚点**，不是第二个状态源 ——
  状态与归属仍只由 `manifest.json` 与 GitHub 侧对象决定。
- 卸载不删除被自己删空的目录之外的任何目录；被删空的受管父目录（如 `.github/ISSUE_TEMPLATE/`）
  会用 `rmdir` 清理（目录非空时 `rmdir` 自动失败，不会误删）。
- `eject.sh` **不**新增/修改 `manifest.json`；`--apply` 只读归属记账并写 tombstone。
