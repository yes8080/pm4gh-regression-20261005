# 可移植治理套件（toolkit）

> **一页讲清：声明的什么、装的什么、状态的账在哪、怎么撤。**
> 本目录是 Issue #69（E2-S-A，归属与命名空间层）的交付物，
> 是在 Issue #46（S1 清单+安装）、#47（S2 卸载）与已保全实现 #60/#61 之上的重构：
> **出厂声明 `kit.yaml` + 运行时账 ledger（`<root>/.git/governance-ledger.json`）
> + 安装器 `install.sh` + 卸载器 `eject.sh` + 统一门面 `governance`**。
> 设计依据：设计方案 v2（#68 §2.1–§2.3 / §2.10）与需求基线 #67（NFR-07 / NFR-17 / AC-06 / AC-09）。

## 1. 它是什么

把本仓库已经收敛的治理资产打包成**一份出厂声明（`kit.yaml`）+ 一个安装器 + 一个卸载器**，
可以装进**任意已有仓库**，并且**随时能撤干净**。

| 组成 | 位置 | 进版本库？ | 职责 |
|---|---|---|---|
| **出厂声明** | `toolkit/kit.yaml` | ✅ 进 | 定义「本套件管什么」：受管对象清单、命名空间、参数占位符、卸载语义。**运行时只读** |
| **运行时账** | `<root>/.git/governance-ledger.json` | ❌ **不进** | 记录「本次安装实际创建了什么」（对象、稳定 id、内容指纹、时间、套件版本、`planned/observed/owned`） |
| 安装器 | `toolkit/install.sh` | ✅ | 先读线上实况再决策；三态幂等；冲突不接管；**只写 ledger** |
| 卸载器 | `toolkit/eject.sh` | ✅ | 两阶段 `内容 → 门禁`；只删 owned 且未漂移；tombstone 可续跑 |
| 门面 | `toolkit/governance` | ✅ | `plan/install/check/eject/ledger show/ledger rebuild/invariants` |
| 不变量检查 | `toolkit/scripts/check-invariants.sh` | ✅ | 门禁自包含（不变量 B）/ 命名空间 / 只报告不接管 / 门禁覆盖 / **无 PR 状态一致性** |

- **声明与状态彻底分离**（设计 #68 §2.1；Bug #60 的 P0 根因）：`kit.yaml` 与目标仓库无关、可审计可 diff；
  目标特有状态一律写进 ledger。`install.sh` 收尾会断言 `kit.yaml` **逐字节未变**。
- **零新增运行时依赖**：`bash`（3.2 兼容）/ `git` / `gh` / `jq` / `python3`（仅用于把 `kit.yaml` 解析成 JSON）。
- **不接管用户既有配置**：对象已存在但不是本套件创建 → **不覆盖、不接管、不静默合并，只报告**。
- **绝不就地改写用户既有文件**（NFR-17）：CODEOWNERS **只给建议行、从不写入**。
- **归属/漂移判定只有一份实现**：`install.sh` 与 `eject.sh` 共用 `toolkit/lib.sh`。

## 2. 命名空间归属（设计 #68 §2.2 / PM 决策 P-5）

**每个由套件创建的对象都必须能自证归属 —— 不依赖 ledger。** 这样「ledger 丢失」只丢历史细节，**不丢卸载能力**。

| 类别 | 命名空间 | 实测 |
|---|---|---|
| 受管**文件** | `.github/governance/**` | ✅ |
| 受管 **workflow** | `.github/workflows/governance-*.yml` | ✅ |
| **标签** | 前缀 `gov/`（见下方偏离说明） | ⚠️ 未使用，理由见下 |
| **规则集** | 前缀 `governance-` | ✅（目标仓库内新建的规则集一律带前缀） |
| **套件自身** | `.github/governance/kit/**` | ✅ |

**平台强制路径的显式豁免**（GitHub 只从固定路径读取，官方无配置项）：

| 路径 | 为什么豁免 |
|---|---|
| `.github/ISSUE_TEMPLATE/**` | GitHub 只从该目录读取 Issue 模板 |
| `.github/PULL_REQUEST_TEMPLATE.md` | GitHub 只从该路径读取 PR 模板 |

豁免**必须逐条写理由**（`kit.yaml` 的 `namespace.file_exemptions` / `label_exemptions`），
`install.sh` 与 `check-invariants.sh` 都会硬校验：受管对象越界、或豁免缺理由 → **失败**。

> **⚠️ 对 P-5「标签 `gov/`」的显式偏离（需 PM 追认）**
> 流程契约标签（`status/*`、`type/*`、`role/*`、`area/*`、`prio/*`、`size/*`、`src/*`、`risk/*`）
> **保持原名**，未加 `gov/` 前缀。理由：它们是**已冻结的流程契约** —— 状态机（GOVERNANCE §4 / D9）、
> `ci/test` 的「状态标签合法且互斥」、`policy/branch-name` 的状态机闸门、Issue 模板的标签引用、
> 以及度量口径（GOVERNANCE §8 返修率 = 带 `src/rework` 的 Issue）同时依赖它们；
> 改名属**治理变更**，不在 S-A 范围。因此 `gov/` 命名空间目前对**套件自有的归属标记标签**生效
> （本切片未新增此类标签），豁免清单覆盖全部受管标签，且每条都写了理由。
> 该偏离已登记在 Issue #69 与交付 PR 中。

**规则集为什么不改源码仓库自身的名字**：本套件源码仓库自身的线上规则集名为 `main-protection`
（建仓时创建）。改名属**线上仓库设置变更**，须由 dispatcher 按 PLAYBOOK §9 实测执行，不在 AI 作者权限内。
因此源码仓库自身的 `.github/rulesets/main-protection.json` 保持原名，与 `payload/main-protection.json`
的差异**只有两处**（`name` 与 `require_code_owner_review`），并由自检 T0.16 断言。

## 3. 受管对象（install 形态）

| 类别 | 内容 | 数量 |
|---|---|---|
| `files` | `.github/governance/labels.yml`、`.github/governance/rulesets/governance-main-protection.json`、`.github/governance/authorized-identities.txt`、`.github/PULL_REQUEST_TEMPLATE.md`、`.github/ISSUE_TEMPLATE/*.yml`（6） | 10 |
| `labels` | 类型/角色/领域/来源/优先级/规模/状态/风险 标签（值取自 `payload/labels.yml`） | 35 |
| `rulesets` | `governance-main-protection`（目标 `~DEFAULT_BRANCH`、必需检查 5 项、审批/仅 squash 等；**不开 `require_code_owner_review`**，见 §7） | 1 |
| `workflows` | `governance-checks.yml`（`ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template`）、`governance-acceptance.yml`（`qa/acceptance`，非必需审计检查）、`governance-state.yml`（`ci/state`，**非 PR 触发器**，见 §8） | 3 |
| `collaborators` | 作者身份、独立评审/验收身份（`permission=push`，**持久权限**） | 2 |
| `kit` | **套件自身整树**，装配到 `.github/governance/kit/**`。目的是让装出来的必需检查**自足**：`ci/lint` 的 `git ls-files '*.sh'` 覆盖面非空、`ci/test` 引用的自检脚本与标签解析器必然存在（Bug #61 F2） | 1（整树） |
| ~~`codeowners`~~ | **已移除**：CODEOWNERS **只报告、不写入**（NFR-17；采用者侧不使用 `require_code_owner_review`） | 0 |

`payload/**` 是策略正文；其中身份/仓库相关与**具体安装路径**都写成占位符
（`@@OWNER@@`、`@@OWNER_MENTION@@`、`@@REVIEWER_ACCOUNT@@`、`@@REVIEWER_MENTION@@`、`@@AUTHOR_ACCOUNT@@`、
`@@REPO@@`、`@@DEFAULT_BRANCH@@`、`@@KIT_ROOT@@`、`@@KIT_GOVERNANCE_DIR@@`、`@@RULESET_DECL_PATH@@`、
`@@CODEOWNERS_PATH@@`、`@@WORKFLOWS_GLOB@@`、`@@CODE_OWNER_IDS@@`），安装时按目标仓库替换 ——
**套件内没有任何硬编码的仓库名或账号**（自检 T0.1/T0.2 强制；`@@…@@` → 具体值的映射写在
`kit.yaml` 的 `placeholders` 段，不变量检查用同一张表把引用解析回真实路径）。

## 4. 怎么用

```bash
# ① 只预告，零写入（默认模式）
toolkit/governance plan                # = install.sh --dry-run
toolkit/governance eject               # = eject.sh --dry-run

# ② 只校验：比对线上实况与 kit.yaml 期望，漂移只报告（退出码 1 = 有漂移）
toolkit/governance check               # = install.sh --check
toolkit/eject.sh --check               # 核验"是否已回到装机前状态"

# ③ 真正安装 / 真正卸载（都幂等；都可中断续跑）
toolkit/governance install                       # = install.sh --apply
toolkit/eject.sh --apply                         # 阶段 A：只做"内容"，然后停在"需通过 PR 落地"
toolkit/eject.sh --apply --after-content-landed   # 阶段 B：内容已由 PR 合并后，删标签 → 规则集 → 协作者
toolkit/eject.sh --apply --allow-ungated          # 无可用门禁通道时，显式承认"将在无门禁状态下推送"
toolkit/eject.sh --apply --force                   # 允许删除**已漂移**的 owned 对象（默认保留）
toolkit/eject.sh --apply --revoke-collaborators    # 显式撤销协作者（默认保留并提示手动命令）

# ④ 运行时账：读它 / 重建它（ledger 丢失不丢卸载能力）
toolkit/governance ledger show          # 它是什么、放哪、丢了怎么办、当前有哪些条目
toolkit/governance ledger show --json   # 机器可读
toolkit/governance ledger rebuild       # 以「命名空间 + 出厂内容指纹」重新 snapshot 线上对象（默认 dry-run）
toolkit/governance ledger rebuild --apply

# ⑤ 不变量检查（离线；采用者仓库里也能跑）
toolkit/governance invariants                    # 全部
toolkit/governance invariants --check state      # 只跑"无 PR 场景状态一致性"
```

> **卸载请优先从"仓库外的套件副本"运行**（`toolkit/eject.sh --root /path/to/target`）：
> 目标仓库里的 `.github/governance/kit/` 是受管对象，就地运行会让"删除套件目录"和"运行套件脚本"互相踩。
> 就地运行时 eject 会把套件目录的删除**延后**到终局阶段，并显式说明（那样它就无法一起走 PR）。

参数（全部可参数化，与 `kit.yaml` 的 `parameters` 段一一对应）：

| 参数 | 环境变量 | 默认来源 |
|---|---|---|
| `--repo OWNER/NAME` | `REPO` | `gh repo view`（当前仓库） |
| `--default-branch NAME` | `DEFAULT_BRANCH` | `gh repo view` 的 `defaultBranchRef` |
| `--owner ACCOUNT` | `OWNER` | `REPO` 的 owner 部分 |
| `--author-account ACCOUNT` | `AUTHOR_ACCOUNT` | 读凭据文件对应身份（默认 `.secrets/developer.pat`） |
| `--reviewer-account ACCOUNT` | `REVIEWER_ACCOUNT` | 读凭据文件对应身份（默认 `.secrets/reviewer.pat`） |
| `--root DIR` | — | 套件目录向上找到的、含 `.git` 的仓库根（也可显式指定） |
| `--kit-dir DIR` / `--kit-yaml FILE` | — | 脚本所在目录 / `<kit-dir>/kit.yaml` |
| `--ledger FILE` | `TOOLKIT_LEDGER` | `<root>/.git/governance-ledger.json`（无 `.git` 时 `<root>/.governance-ledger.json`） |
| `--after-content-landed` | — | （eject）终局阶段：内容已由 PR 落地后才删标签/规则集/协作者 |
| `--allow-ungated` | — | （eject）无可用门禁通道时显式确认"将在无门禁状态下推送" |

**凭据**：脚本只读凭据文件内容用于确认身份，**从不打印、从不落盘**。
`--apply` 创建规则集与协作者需要 **admin 权限**（作者/评审身份只有 write，属预期：这类操作由 dispatcher 执行）。

## 5. 运行时账（ledger）：它是什么、放哪、丢了怎么办

> 这一节同时是设计 #68 §2.1.1 要求的**文档说明**；`governance ledger show` 会把同样内容打印出来。

**它是什么**：安装器的**事务账** —— 记录本套件对远端对象实际做了什么（对象、稳定 id、内容指纹、
时间、套件版本、`planned/observed/owned`）。它**不是**任务/状态账本：任务与状态仍只在 GitHub
（`status/*` 标签 + Issue 开关 + Milestone），因此不违反 NFR-14「单一真相源」。

**它放哪**：`<root>/.git/governance-ledger.json`（出厂声明里的登记值：`kit.yaml` 的 `ledger.path`）。

**为什么放 `.git/` 而不是"仓库内 + gitignore"（设计 #68 决策 P-4 的正面论证）**：

1. F1（Bug #60）的根因是"**状态混进了分发物**"，不是"状态在版本库里"；两条路都能修 F1。
2. 选 `.git/` 的硬理由是 **ledger 必须活过 `git clean -fdx`**：gitignore 方案下它是未跟踪文件，
   会被一条常规清理命令直接抹掉；`.git/` 内的文件不会。这不是理论担忧（自检 T22 实测复现）。
3. **代价如实写明**：它对人不被发现 —— 既不在 `git status`，也不出现在任何 diff / 评审里。
   因此必须提供读取命令（`ledger show`）与本文档说明。
4. 被引先例（Terraform state、changesets、dpkg `DEBIAN/conffiles`）**全部**把账放进版本库；
   本套件是**有理由的偏离**：账本要同时满足"不进分发物"与"活过 `git clean -fdx`"两条它们不需要的约束。

**丢了怎么办**：

```bash
toolkit/governance ledger show            # 先看它现在是什么状态（不存在时会给出重建指引，退出码 1）
toolkit/governance ledger rebuild         # 以「命名空间归属 + 出厂内容指纹」重新 snapshot 线上对象（dry-run）
toolkit/governance ledger rebuild --apply # 落盘
```

- **丢失不丢卸载能力**（设计 #68 §2.2）：归属由**命名空间**自证，只是丢掉"历史细节"（谁在何时改过）。
- `rebuild` 的自证判据：文件 / workflow / 套件树 → 目标内容与**出厂渲染内容**逐字节一致才算 owned；
  标签 / 规则集 → 线上值与出厂声明一致才算 owned；**协作者属持久权限，命名空间无法自证 → 一律保守标记
  `owned=false` 并报告**（绝不据此撤销）。因此 `rebuild` 在有此类对象时以退出码 1 结束 = "有需人工决定项"。
- 记账**绝不能被 git 跟踪**：`install.sh` / `eject.sh` 启动时 `git ls-files --error-unmatch` 校验并拒绝。
- 记账缺失时：`install.sh --check`、`eject.sh --check/--apply` **明确报错（退出码 2）**，
  绝不静默按"全部装机前已存在"处理（那样既不报漂移、也无法卸载）。只有 `install.sh --apply` 会创建它。

## 6. 三种状态的幂等语义（planned → observed → owned）

| 状态 | 含义 | 谁来定 |
|---|---|---|
| `planned` | `kit.yaml` 里声明的期望；`--apply` 时的"写前落账"（`intent=create`） | 声明（人写的）+ 执行前的意图登记 |
| `observed` | **本次运行现读的线上实况** | 每次运行重新探测；**绝不用上一次的记账代替观测** |
| `owned` | 本套件创建或明确接管（成功后回读确认） | 回读确认后写入 ledger |

- **重试语义**：上一次命令报错、但对象其实已创建 → 记账里留有 `create` 意图，且本次实况存在
  → 仍判 `owned=true`，不会被误当成"用户既有对象"而漏记（失败案例库 D6 的直接教训）。
- **重复 install 是 no-op**：所有对象都命中"已存在且一致" → 0 创建 / 0 更新 / 0 写入。
- **冲突不静默**：`--apply` 遇到"非本套件创建且与期望不一致"的对象会跳过它并以退出码 1 结束，
  等人工决定，**不会**替用户改配置；ledger 里记 `pre_existing=true / owned=false`。

退出码：`0` 无漂移/安装成功；`1` 有漂移或冲突；`2` 参数或环境错误。

## 7. 怎么撤（`eject.sh`）

**四条语义**：

| # | 语义 | 实现 |
|---|---|---|
| ① | **只删 owned 且未漂移** | 逐个受管对象比对"期望内容 vs 现读实况"：`owned=true`（或留有 `create` 意图，D6）且**未漂移**才删；`pre_existing`/非本套件对象**只报告、绝不删** |
| ② | **漂移默认保留** | 内容/颜色/参数与期望不一致 → `[保留]` 并计入小结，**需显式 `--force` 才删**（`--apply` 此时退出码 1 = 需人工决定） |
| ③ | **协作者询问式** | 持久权限：默认**保留** + 报告 + 打印手动撤销命令；只有显式 `--revoke-collaborators` 才撤销，**绝不静默撤销** |
| ④ | **tombstone（可中断可续跑）** | 任何不可逆动作**之前**先写 `<root>/.git/governance-eject-tombstone.json`（计划 + 装机前 baseline + 可恢复锚点）与 `…-record.md`（可选 `--record-issue N` 写入 Issue），并备份文件内容/规则集正文到 `…-backup/`；中断后**重跑即续跑** |

**删除顺序（Bug #60 追加要求：先内容、后门禁）**

| 阶段 | 内容 | 门禁状态 |
|---|---|---|
| **A · 内容** | 受管文件 / workflow / 套件目录（**工作区删除，必须通过 PR 落地**） | 规则集**仍生效** |
| **B · 平台对象** | 受管标签（PR 合并后再删：`policy/branch-name` 依赖 `status/*` 标签） | 规则集仍生效 |
| **C · 门禁本体** | 规则集 | **最后**移除 |
| **D · 持久权限** | 协作者（默认保留，询问式） | — |

`eject.sh --apply` 做完阶段 A 就**停下并退出码 1**，打印"通过 PR 落地"的命令；
合并后重跑 `--after-content-landed` 才进入 B/C/D。

**CODEOWNERS 的处理（NFR-17）**：本套件**不写入**用户 CODEOWNERS（只给建议行），因此卸载也不删它；
`--check` 断言它**逐字节未变**（整文件指纹，基线缺文件时记 `ABSENT`）—— 这比"只保护我们没写的行"更强。

## 8. 两条机器不变量（`check-invariants.sh`，已接入 `ci/test`）

| 检查 | 判据 | 对应的真实缺陷 |
|---|---|---|
| `invariant-b` | **不变量 B「门禁自包含」**：payload 引用集 ⊆ 安装集（占位符按 `kit.yaml.placeholders` 解析回真实路径后再断言） | #61 F2/F3：装出去的必需检查引用了未安装的宿主私有资产 → 假绿或直接失败 |
| `namespace` | 受管对象必须在命名空间内，或逐条豁免且写明理由 | P-5；越界写入用户配置空间 |
| `codeowners` | 套件不把 CODEOWNERS 当受管对象；payload 规则集**不得**开 `require_code_owner_review` | F4 / Bug #62、Bug #13：装出一个套件自己无法满足的门禁 |
| `gates` | 规则集里的必需检查必须都有受管 workflow 的 job | 必需检查永久 pending |
| `state` | **无 PR 场景的状态一致性**（见下） | 缺口：5 项必需检查只在 PR 上跑，没有 PR 时从不运行 |

**提取口径写清楚（否则会退化成"看起来在跑其实什么都没验"）**：只取**命令位置**的路径引用；
`echo`/`printf` 的消息文本不是执行依赖（早期版本把消息里的 `scripts/status.sh` 误报成依赖，全是假阳性）；
单引号串（grep/jq 表达式）先剥掉，双引号串保留（命令替换里的路径是真依赖）。
**边界**：只检查门禁的执行依赖，不检查文档 URL / 注释举例。

**补「无 PR 时门禁停摆」缺口**：新增 `.github/workflows/governance-state.yml`（job `ci/state`，
**非必需检查**，`on: push`（默认分支）+ `workflow_dispatch`），它在**没有 PR** 的场景下跑
`check-invariants.sh --check state`：

1. **触发器自守**：状态工作流源文件必须声明 `push:` 与 `workflow_dispatch:` —— 删掉任何一个即失败，
   缺口不会静默回归（自检 T23.12 是它的反向样本）；
2. **状态一致性**：命名空间 + 不变量 B + 只报告不接管 + 门禁覆盖在同一场景下也必须成立；
3. **记账与实况一致**：ledger 存在时，`owned=true` 的文件/workflow 对象必须真的在；
   ledger 不存在时（CI 的正常状态，它在 `.git/` 下不进版本库）显式说明并**以命名空间兜底** ——
   这等于让"ledger 丢失路径"在每次 push 时都被常态化演练一次。

> ⚠️ `ci/state` **不是**必需检查，也**不得**加进必需清单：必需检查集合一变，所有在飞的 PR 会立刻 pending。

同一套不变量在 `ci/test`（必需检查）里也跑一遍（`--check invariant-b --check namespace --check codeowners --check gates`），
所以**破坏不变量 B 或命名空间的 PR 会被直接拦下**。

## 9. 自检与验证

```bash
# 离线自检（不联网、不碰任何真实仓库）：290 条断言
bash toolkit/tests/self-test.sh

# 不变量检查（离线；在源码仓库或采用者仓库里都能跑）
bash toolkit/scripts/check-invariants.sh

# 在宿主仓库上核对"与现状一致"（只读）
toolkit/governance check
toolkit/eject.sh --check
```

**这条自检已接入 CI 门禁**：必需检查 `ci/test` 中有一节
`toolkit 自检（install/eject 语义：存在即执行、缺失即失败）`，它真实执行本脚本，
并按契约处理两种边界：

- **失败即失败**：任何 `[FAIL]` → 该步骤非零退出 → `ci/test` 变红（不吞输出、不 `|| true`）；
- **缺失即失败**：脚本被删除或改名时**直接报错退出**，绝不当作"没找到就跳过"。

同一节也同步写进了 `payload/workflows/governance-checks.yml`，因此装到目标仓库的 CI 同样包含它
（两处内容除占位符外必须逐字一致，自检 T0.15 逐行断言）。

**S-A 专项断言**：

| 组 | 断言 |
|---|---|
| T0.3–T0.14 | `kit.yaml` 可被严格子集解析器解析；不含运行时账；记账落点在 `.git/`；CODEOWNERS 不再受管；占位符表与声明/安装集一致 |
| T0.15–T0.17 | payload 与源码仓库自身的 workflow 差异**只来自占位符**（逐行 + 配对）；规则集差异只有 `name` 与 code-owner 开关；采用者侧不开 `require_code_owner_review` |
| T0.18–T0.21 | **YAML 解析器反向样本**：流式集合 / 制表符缩进 / 重复键 / 锚点必须报错（不得静默误读，F12 的教训） |
| T3.5–T3.23 | 文件落在 `.github/governance/**`、workflow 落在 `governance-*.yml`、**CODEOWNERS 未被创建**（只报告）；ledger 三态字段齐备；`kit.yaml` 逐字节未变；安装后不变量检查在目标仓库内通过 |
| T9 | **反向样本**：声明与 payload 标签不一致 → `--apply` 失败 |
| T10–T16 | eject 两阶段 / 漂移保留 / 协作者询问式 / 中断续跑 / 只删 owned / 用户对象一个不少（含反向样本） |
| T17 | **反向样本**：把运行时账注入出厂声明 → 套件自检必须失败（点名 T0.4） |
| T18 | **反向样本**：抽取真实 workflow 步骤正文，在缺资产时用 `bash -e` 执行必须非零退出；旧写法同场景退出码 0（复现 #61 F3 假绿） |
| T20 | **反向样本**：无可用门禁通道 → 显式报告 + 拒绝静默直推 + `--allow-ungated` 才继续 |
| T21 | `ledger show`（内容/来源/去向/丢了怎么办/`--json`）；账本丢失后 `--check` 报错并给出重建命令；`ledger rebuild` 恢复后仍能正常卸载（**ledger 丢失不丢卸载能力**） |
| T22 | **ledger 活过 `git clean -fdx`**（选 `.git/` 的硬理由，实测复现；同一命令确实清掉了未跟踪的受管文件） |
| T23 | 不变量检查全绿；**反向样本 A–E**：引用未安装资产 / 文件越界 / 开不可满足的门禁 / 删掉非 PR 触发器 / workflow 脱离命名空间 —— 每一种都必须让对应检查失败 |

> `TOOLKIT_EJECT_ABORT_AFTER=<class>:<id>` 是**仅供自检**的中断接缝（完成该对象后 `exit 3`），生产不使用。

## 10. 已知边界

- 不实现策略开关与跨模型评审（后续切片）；不管理目标仓库的业务代码与业务 CI；不引入 Projects。
- 文件类对象的比对基准是**宿主仓库工作区**（`--root` 下的文件），不是远端默认分支的副本。
- tombstone / 记录 / 备份 / ledger 落在**宿主仓库的 `.git/` 下**（`--tombstone` / `--ledger` 可改路径）：
  它们是"这台机器上的这次操作"的**事务记录与锚点**，不是第二个状态源。
- 卸载不删除被自己删空的受管目录以外的任何目录；空目录用 `rmdir` 清理（非空时自动失败，不会误删）。
- **就地运行（KIT_DIR 就在目标仓库的 `.github/governance/kit/`）时**，套件目录的删除会延后到终局阶段 ——
  脚本不能在自己还需要运行时把自己删掉。推荐用仓库外的套件副本运行（`--root`）。
- 不承诺"卸载 = dpkg 级精确还原"：GitHub 端对象带外部副作用（协作者邀请等），
  本套件只承诺"命名空间内可自证归属 + 差异可见"（设计 #68 §2.5/§2.10 的边界）。
- 源码仓库自身的线上规则集名（`main-protection`）**未**跟随命名空间改名 ——
  属线上仓库设置变更，须由 dispatcher 按 PLAYBOOK §9 执行。

## 11. 关键实现决定（Bug #60 / #61 + S-A）

**#61 F2 选了"把依赖资产纳入套件并登记"，而不是"让检查在资产缺失时明确失败"。理由：**

1. 「缺失即失败」只能让目标仓库上的必需检查**永久变红**，等于把套件装成一个"装完就无法通过自己门禁"的东西
   —— 那正是 #60/#61 描述的 P0 形态，不是修复。要让它变绿，资产终归要被安装。
2. 依赖资产本来就是**套件自己的文件**（标签解析器 + 自检装置），把它们移进 `toolkit/`
   并在 `objects.kit` 登记，正好满足 Epic #43 §②「`toolkit/` 应含 `scripts/`」的形态要求。
3. 只做"明确失败"还留下**覆盖面为空**的隐患：`ci/lint` 的 `git ls-files '*.sh'` 在非 shell 项目上返回空集
   → 工作流显式 `exit 1`；纳入套件后覆盖面天然非空。
4. 两条护栏**同时**保留：资产缺失时仍然是**明确失败**（#61 F3 的显式存在性守卫）。

**#60 F1（在 S-A 中按新设计重做）**：`manifest.json` → **`kit.yaml`**（真 YAML，由自带的严格子集解析器
`scripts/yaml2json.py` 转 JSON；**不支持的构造一律报错，绝不猜测**）；ledger 移到
`<root>/.git/governance-ledger.json`；`--check` 缺记账直接报错；反向样本（T17）证明护栏仍然有效。

**S-A 相对已保全实现（`e99406e`）的改造**（评估结论：**需改造**，见交付 PR）：

| 项 | e99406e | S-A |
|---|---|---|
| 声明文件 | `toolkit/manifest.json`（JSON） | `toolkit/kit.yaml`（YAML + 严格子集解析器） |
| 记账落点 | `.git/toolkit-ledger.json` | `.git/governance-ledger.json` |
| 命名空间 | 无（文件在 `.github/*`、规则集 `main-protection`） | 文件 `.github/governance/**`、workflow `governance-*.yml`、规则集 `governance-*`、套件 `.github/governance/kit/**` |
| CODEOWNERS | 仍向用户文件**追加**行（F4） | **只报告、不写入**（NFR-17），配套关闭采用者侧 `require_code_owner_review` |
| 账本命令 | 无 | `ledger show` / `ledger rebuild`（丢失可恢复） |
| 不变量 B | 只有针对 `*.sh` 的窄检查（T0.6） | 独立检查脚本 + `ci/test` 常设 + 反向样本 A–E |
| 无 PR 缺口 | 未处理 | `governance-state.yml`（`ci/state`，非 PR 触发器）+ 触发器自守断言 |
| eject 分阶段卸载 | 已实现 | 原样沿用（与 ledger 出库强耦合），**如 PM 认为应拆到 S-C 可在评审中要求拆分** |
