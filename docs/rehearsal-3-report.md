# 第三次演练报告 —— 真装真撤（临时仓库，零损伤证明）

> **对应切片**：Issue [#48](https://github.com/yes8080/pm4gh/issues/48)（E2-S3，Epic [#43](https://github.com/yes8080/pm4gh/issues/43) 的核心验收切片）
> **执行者**：作者身份 `@yes8080-dev-bot`；仓库管理动作（建仓/装规则集/邀协作者/合并/删仓）= dispatcher `@yes8080`；评审/验收 = `@yes8080-reviewer-bot`
> **目标仓库**：`yes8080/pm4gh-kit-rehearsal`（**私有、临时、用完即删**；创建 `2026-10-04T08:15:32Z`）

---

## 0. 结论先行

| 验收项 | 结论 | 证据 |
|---|---|---|
| ① `install.sh --dry-run` → 人工过目 → 真实 install | ✅ 通过 | §2；dry-run 56 项预告 + 零写入核验；`--apply` 56 创建 / 0 冲突 / 退出码 0；第 2、3 次执行均为 **0 创建 / 56 已存在一致**（幂等） |
| ② 装机前后完整比对（git status/标签/规则集/workflow/协作者/CODEOWNERS） | ✅ 通过 | §2.3、§5.3 逐项比对表 |
| ③ 目标仓库最小闭环（分支→PR→必需检查→非作者 approve→dispatcher 合并→收尾五项） | ✅ 通过（**带一处保留意见**） | §4：两次闭环 PR 均为 5 项必需检查全绿 + 非作者 approve + dispatcher squash 合并；保留意见 = 收尾第 ⑤ 项（无残留 `status/*`）**套件不提供迁移工具**，只能人工收口（缺陷 F5 / Bug [#63](https://github.com/yes8080/pm4gh/issues/63)） |
| ④ `eject.sh` 零损伤证明 | ✅ 通过 | §5：`--apply` 54 删除 / 0 失败 / 退出码 0；`--check` **退出码 0**（59 项通过 / 0 失败）；`origin/main` 文件树与装机前 baseline `6fe062a` **逐字节一致** |
| ⑤ 可移植性缺陷清单 | ✅ 产出 12 项（4 项已开 Bug） | §6 |
| ⑥ 删除临时仓库 + 可恢复证据 | ⚠️ **未完成（环境凭据限制）** | §7：主身份 `gh` 登录 **无 `delete_repo` scope**，两个 bot PAT 也没有；已把仓库置为 **archived（只读）** 过渡，附可恢复锚点与人工删除命令 |
| ⑦ 新坑写进 `docs/PLAYBOOK.md` §4 | ✅ 通过 | 本 PR 同时更新 PLAYBOOK §4（6 条新陷阱） |

**一句话结论**：`install.sh` / `eject.sh` 的**归属与可逆性**在真实仓库上成立且可证明零损伤；
但**套件装出来的门禁在目标仓库上并非"装好即用"** —— 它自带一个必然变红的必需检查（F1/F2，已开 P0 Bug），
首次落地依赖一个文档未写明的 bootstrap PR，状态机与 CODEOWNERS 语义也有接管副作用。

---

## 1. 演练设定

| 项 | 内容 |
|---|---|
| 目标 | 证明"**能装进任意已有仓库、且用完能撤干净**" |
| 目标仓库 | **新建**私有仓库 `yes8080/pm4gh-kit-rehearsal`（PM 决策：绝不拿真实项目冒险） |
| 仓库基线（"装机前既有对象"） | `README.md`、`legacy/notes.md`、`.github/legacy-notes.md`、`.github/workflows/legacy-ci.yml`（产出非必需检查 `legacy/hello`）、`.github/CODEOWNERS`（既有行 `/legacy/ @yes8080`）、标签 `legacy/keep`（`5319E7`）、规则集 `legacy-branch-protection`（id `24450303`，只保护 `refs/heads/legacy-protected`）、git tag `v0.0.1-legacy`、以及 GitHub 自带的 10 个默认标签 |
| 三身份结构 | `yes8080`（admin）、`yes8080-dev-bot`（write）、`yes8080-reviewer-bot`（write）—— 后两者由 `install.sh --apply` 邀请、由各自 PAT 接受（W0.4 第 4/5 步） |
| 套件来源 | `toolkit/` 由 pm4gh 原样 vendor 进目标仓库工作区（`cp -R`，**未新增任何依赖或脚本**，满足"轻量化硬要求"） |
| 时间线 | 建仓 `08:15:32Z` → 装机完成 `08:17Z` → 闭环 #1 合并 `08:28:27Z` → 闭环 #2 合并 `08:31:25Z` → `eject --apply` 完成 `08:33Z` → 归档过渡 `08:34Z`（**约 19 分钟**，不含文档与 PR） |

**身份纪律执行情况**：建仓/装规则集/邀协作者/合并/删除尝试 = dispatcher；Issue、分支、提交、PR、业务改动 = `yes8080-dev-bot`（`git -c user.name/user.email` 显式指定）；approve = `yes8080-reviewer-bot`。**全程未打印/提交任何 token，未改动 pm4gh 的仓库设置、规则集与协作者。**

---

## 2. 装机

### 2.1 `--dry-run`（人工过目）

```text
[INFO] 读取线上实况（每次运行都重新读，不用记账代替观测）
[ OK ] 标签 …live_labels.tsv：11 条线上标签（仅比对 manifest 登记项）
[ OK ] 协作者：1 个；规则集：1 个
… files（10）/ labels（35）/ rulesets（1）/ workflows（2）/ codeowners（6）/ collaborators（2）…
[ OK ] 规则集引用的必需检查全部有对应 job
[INFO] 小结（模式：dry-run）
  将创建/已创建：56    将更新/已更新：0    已存在且一致：0
  冲突（非本套件创建，不覆盖不接管）：0    失败：0
[ OK ] dry-run 结束：零写入。
```

预告 = **56 = 10 文件 + 35 标签 + 1 规则集 + 2 workflow + 6 CODEOWNERS 行 + 2 协作者**，与 README §2 的登记一致。

**零写入核验（dry-run 后立刻回读）**：`git status` 只有我们手工 vendor 的 `?? toolkit/`；
标签仍 11 条；规则集仍 1 个；协作者仍只有 `yes8080`；12 个受管文件工作区全部不存在；`manifest.json` 的 `ledger` 无条目。

### 2.2 真实 `install.sh --apply`

| 轮次 | 结果 | 退出码 |
|---|---|---|
| 第 1 次 | 创建 56 / 冲突 0 / 失败 0；邀请 2 个协作者（pending，**按 D6"写前落账 + 回读确认"语义暂记 owned=54**） | `0` |
| 协作者接受邀请后第 2 次 | **0 创建 / 56 已存在且一致**；ledger 变为 `owned=true` 56 个（D6 重试语义生效） | `0` |
| 第 3 次 | 同上（**重复 install 是 no-op**） | `0` |

**冲突保护实测**：装机前后的线上差异里，非受管对象（`legacy/keep` 标签、`legacy-branch-protection` 规则集、
10 个 GitHub 默认标签、既有 CODEOWNERS 行、`legacy-ci.yml`）**一律未出现在 install 的写入面**，`冲突=0`。

### 2.3 装机前后**完整比对**

| 类别 | 装机前 | 装机后 | 判定 |
|---|---|---|---|
| `git status`（工作区） | 干净 | ` M .github/CODEOWNERS` + 8 项未跟踪（12 个受管文件中的 11 个 .github 文件与 `toolkit/`） | 预期（install 只写工作区，见 F6/F9） |
| GitHub 标签 | **11**（10 默认 + `legacy/keep`） | **46**（11 + 35 受管） | 只增不覆盖 |
| 规则集 | **1**（`legacy-branch-protection` 24450303） | **2**（+ `main-protection` 24450320） | 既有规则集未被改动，见 §2.4 |
| workflow 文件 | **1**（`legacy-ci.yml`） | **3**（+ `required-checks.yml`、`acceptance-check.yml`） | 只增 |
| 协作者 | **1**（`yes8080` admin） | **3**（+ 两个 bot，`push=true / admin=false`） | 预期（PM 决策 3） |
| CODEOWNERS | 2 行（注释 + `/legacy/ @yes8080`） | 2 行 + 套件追加的 6 行（**原有 2 行逐字保留**） | 文本未动；**语义被接管**，见 F4 |
| 仓库设置 | `allow_merge_commit=true`、`allow_rebase_merge=true`、`allow_squash_merge=true`、`delete_branch_on_merge=false` | 同左（套件不管理仓库设置） | 未越界，见 F11 |

`main-protection` 线上全文与 `payload/main-protection.json` 语义一致（`gh api repos/…/rulesets/24450320` 逐字段比对，
`bypass_actors: []`、5 项必需检查、`require_code_owner_review=true`、`allowed_merge_methods=["squash"]`）。

### 2.4 既有对象未被接管（装机后回读）

```text
规则集：24450303  legacy-branch-protection  branch  active   ← 原始 id / 原始 JSON 未变
        24450320  main-protection           branch  active   ← 本套件创建
标签：  accessibility/bug/documentation/…/wontfix（10 个平台默认，颜色描述未变）
        legacy/keep  5319E7  安装前既有的标签（非本套件，eject 不得删）
CODEOWNERS：原有注释行 + /legacy/ @yes8080 逐字保留
```

---

## 3. 目标仓库的三身份结构

```text
$ gh api repos/yes8080/pm4gh-kit-rehearsal/collaborators
yes8080               push=true  admin=true   role=admin
yes8080-dev-bot       push=true  admin=false  role=write
yes8080-reviewer-bot  push=true  admin=false  role=write
```

- 邀请由 `install.sh --apply` 发出（`[apply] 邀请 collaborator …`，`permission=push`）；
- 接受由各自 classic PAT 执行（`user/repository_invitations` → `PATCH`，均返回 204 成功）；
- 回读验证：两个 bot 各自 `gh api repos/… --jq .permissions.push` = `true`，且能看到私有仓库（404 反证不存在）。
- 这两个协作者在 `manifest.json` 中登记为 `collaborators`，`eject.sh` 按**持久权限询问式**处理（默认保留 + 报告 + 手动撤销命令）。

---

## 4. 最小闭环（在该仓库跑通）

### 4.1 闭环 #1：把套件自身落地默认分支（bootstrap）

> ⚠️ 这是**文档未写明的必需步骤**：`install.sh` 只写工作区不提交，而 `main-protection` 在同一轮就已 active 且
> `bypass_actors=[]`（实测同类规则集的 `current_user_can_bypass = "never"`）→ 受管文件**无法直推 main**，
> 只能靠一个"自己的门禁由 PR 自身的工作流提供"的 PR 落地。详见缺陷 F6。

| 环节 | 结果 |
|---|---|
| Issue | 目标仓库 #1（作者身份创建，带 `status/in-progress`） |
| 分支 | `slice/1-land-governance-kit`（作者身份推送） |
| PR | 目标仓库 **PR #2**（六段正文 + `Closes #1`） |
| 必需检查（首个 SHA `bd746fd`） | `ci/lint` pass、`policy/linked-issue` pass、`policy/branch-name` pass、`policy/template` pass、**`ci/test` fail** → `mergeStateStatus=BLOCKED` |
| 根因原文 | `[FAIL] T0.1 toolkit/ 内无 yes8080（… manifest.json:781: "collaborator:yes8080-dev-bot" …）`、`T6.1/T6.5/T6.6/T14.1/T14.2/T14.3/T14.5/T14.6` → **`自检结果：PASS=141 FAIL=13`** / `##[error]toolkit 自检失败（退出码 1）` |
| 修复提交 `1124cde` | `manifest.json` 以**出厂状态**入库（本机另存带 ledger 的副本供 `eject`）→ **新 SHA 获得全新检查结论** |
| 必需检查（修复 SHA `1124cde`） | `ci/lint` pass、`ci/test` **pass**、`policy/linked-issue` pass、`policy/branch-name` pass、`policy/template` pass |
| 非必需审计检查 | `qa/acceptance` fail（D5 设计如此：批准前必然"先失败"）、`legacy/hello` pass（既有 CI） |
| 评审 | `reviewDecision=APPROVED`（`yes8080-reviewer-bot`，非作者） |
| 合并 | **dispatcher `yes8080`** `gh pr merge 2 --squash --delete-branch` → `MERGED`（squash `7976d4a`，`mergedAt=08:28:27Z`，`mergedBy=yes8080`） |
| 收尾五项 | ①`MERGED` ②Issue #1 `CLOSED/COMPLETED`（`Closes #1` 自动关单）③远程分支已删（`git ls-remote` 0 条）④本地分支已删 ⑤**残留 `status/in-progress`** → 套件无 `scripts/status.sh`，人工等价清理后通过（F5 / Bug #63） |

### 4.2 闭环 #2：普通业务改动（稳态门禁）

| 环节 | 结果 |
|---|---|
| Issue | 目标仓库 #3 |
| 分支 / PR | `slice/3-business-note` → 目标仓库 **PR #4**（改 `legacy/notes.md`，`Closes #3`） |
| 必需检查 | 5 项**全绿**（`ci/lint`、`ci/test`、`policy/linked-issue`、`policy/branch-name`、`policy/template`） |
| 评审 | 仅 `yes8080-reviewer-bot` 一人 approve → `reviewDecision=APPROVED`、`mergeStateStatus=UNSTABLE`（非 `BLOCKED`） |
| 合并 | dispatcher squash → `MERGED`；收尾五项同 4.1（同样残留 `status/in-progress`，人工清理） |

> **这一条同时是一次对照实验**：本 PR 只改 `legacy/notes.md`，而 CODEOWNERS 里用户原有行是 `/legacy/ @yes8080`。
> `reviewer-bot` **不在**该行的 owner 里，却让 `require_code_owner_review` 得到满足 → 证明套件追加在**末尾**的
> `* @yes8080 @yes8080-reviewer-bot` 覆盖了用户原有规则（CODEOWNERS 以**最后匹配**为准）。见 F4 / Bug #62。

### 4.3 门禁与身份的实际结论

- 5 项必需检查在目标仓库**能正常上报、能改名不改地流转**，`strict_required_status_checks_policy` 未造成 pending；
- 作者**无法**自我批准（平台拒绝），评审身份是唯一非作者批准者；
- `mergeStateStatus=UNSTABLE`（非必需 `qa/acceptance` 红）**不阻塞合并** —— 与 PLAYBOOK §8 一致；
- **只有 dispatcher 合并**，两次合并的 `mergedBy` 均为 `yes8080`。

---

## 5. 卸载与零损伤证明

### 5.1 `eject.sh` 三轮结果

| 命令 | 退出码 | 结果 |
|---|---|---|
| `eject.sh --dry-run` | `0` | 预告：**将删除 54**（10 文件 + 35 标签 + 1 规则集 + 2 workflow + 6 CODEOWNERS 行）、**协作者保留 2**、漂移保留 0、非本套件对象保留 0；零写入 |
| `eject.sh --apply` | `0` | **已删除 54 / 删除失败 0 / 漂移保留 0 / 非本套件保留 0 / 协作者保留 2（询问式）**；tombstone + oplog + backup + record 已落 `<root>/.git/` |
| `eject.sh --check` | `0` | **通过检查项 59 / 未通过 0**；"与装机前一致（例外：2 个协作者属持久权限，按询问式语义保留并已报告，未静默撤销）" |
| `eject.sh --dry-run --revoke-collaborators` | `0` | 预告撤销 2 个协作者（**仅预告、未执行**，遵守 PM 决策 3 的"默认保留"） |
| `install.sh --check`（交叉印证） | `1` | **54 处漂移 / 0 失败** —— 每个受管对象都被报成"缺失/漂移"，即"受管对象全消失" |

### 5.2 卸载结果落地（端到端）

`eject.sh` 的契约是**宿主工作区**（README §7）：它删除工作区里的受管文件，不 commit/push。
由于 `main-protection` 已随 eject 删除（默认分支重新无门禁），我们把卸载结果直接落到 `main`：

```text
chore: eject.sh 卸载结果落地（受管对象全部移除，原有对象一个不少）(#48)   ac77737
$ git diff --quiet 6fe062a origin/main && echo 一致
[一致] origin/main 的文件树与装机前 baseline 6fe062a 完全相同
```

> 为使比对可判定，该提交同时**移除演练时 vendor 的 `toolkit/`**、并把闭环用的业务改动 `legacy/notes.md`
> 还原为 baseline 内容（闭环改动本就是演练痕迹）。

### 5.3 逐项比对（装机前 vs 卸载后）

| 类别 | 装机前 | 卸载后 | 判定 |
|---|---|---|---|
| **受管 .github 文件（10）** | 不存在 | 全部消失 | ✅ |
| **受管 workflow（2）** | 不存在 | 全部消失 | ✅ |
| **受管标签（35）** | 不存在 | 全部消失（标签总数回到 **11**） | ✅ |
| **受管规则集（1）** | 不存在 | `main-protection` 消失（规则集回到 **1**） | ✅ |
| **受管 CODEOWNERS 行（6）** | 不存在 | 全部消失（文件回到原有 2 行） | ✅ |
| 既有 `.github` 非受管文件（2） | 存在 | 逐字保持原样 | ✅ |
| 既有标签（含 10 个平台默认 + `legacy/keep`） | 11 | 11，颜色/描述逐字一致 | ✅ |
| 既有规则集 `legacy-branch-protection` | id `24450303` | 同 id / 同 JSON | ✅ |
| 既有 workflow `legacy-ci.yml` | 存在 | 逐字保持原样 | ✅ |
| 既有 git tag `v0.0.1-legacy` | 存在 | 存在 | ✅ |
| 既有协作者 `yes8080` | admin | admin | ✅ |
| **受管协作者（2 bot）** | 不存在 | **仍在（询问式保留）** | ⚠️ 设计如此（持久权限例外，已报告 + 给出手动撤销命令） |
| 工作区 `git status`（eject 后、落地前） | 干净 | 13 项 `D` + 1 项 `M`（均为待落地的受管文件删除） | 预期 |
| **整仓文件树** | `6fe062a` | `origin/main` **逐字节一致** | ✅ |

### 5.4 tombstone / 可恢复锚点

```text
<root>/.git/toolkit-eject-tombstone.json        30 588 B（计划 + 装机前 baseline + 可恢复锚点，status=completed）
<root>/.git/toolkit-eject-tombstone.oplog         3 276 B（逐对象操作流水）
<root>/.git/toolkit-eject-tombstone.backup/        目录（受管文件内容与规则集正文备份）
<root>/.git/toolkit-eject-tombstone-record.md    16 087 B（人类可读卸载记录）
```

**零损伤结论**：**受管对象一个不剩、装机前对象一个不少、整仓文件树与 baseline 逐字节一致**；
唯一例外是 2 个协作者按"持久权限询问式"语义保留（**未静默撤销**，符合 Epic #43 §③ 与 PM 决策 3）。

---

## 6. 可移植性缺陷清单（本切片最有价值的产出）

> 编号后带 `→ Bug #NN` 的已开 Issue；其余为演练记录，供 PM 决定是否切片。
> "位置"均以**当前 pm4gh 仓库内的行号**给出。

| # | 严重度 | 缺陷（一句话） | 位置 / 具体假设 | 证据 |
|---|---|---|---|---|
| **F1** | **P0 阻断** → [#60](https://github.com/yes8080/pm4gh/issues/60) | `install.sh --apply` 把**运行时归属 ledger**（含真实账号名、本仓库归属）写进 `toolkit/manifest.json`；该文件同时是分发物、`self-test.sh` T0「kit 内不得硬编码账号」的被检对象、T6/T14「不覆盖不接管」用例的输入 → **真用一次套件就弄红套件自带的必需检查 `ci/test`** | `toolkit/install.sh:472-479`（`finalize_ledger` 写 `$MANIFEST`）、`toolkit/lib.sh:53-63`（`ledger_owned`/`ledger_mark_intent`）、`toolkit/tests/self-test.sh:70-73`（`grep -rn 'yes8080'`）。**身份假设**：ledger 的键 `collaborator:@@AUTHOR_ACCOUNT@@` 渲染后必然含真实登录名 | 目标仓库本地 `PASS=141 FAIL=13`；同 kit 复位 ledger 后 `PASS=154 FAIL=0`；CI 原文 `##[error]toolkit 自检失败（退出码 1）` |
| **F2** | **P0 阻断** → [#61](https://github.com/yes8080/pm4gh/issues/61) | 安装到目标仓库的必需检查**引用 pm4gh 自己的、未被 manifest 登记也不被安装的资产**：`scripts/sync-labels.sh`、`toolkit/tests/self-test.sh`；`ci/lint` 还要求目标仓库至少有 1 个被跟踪 `*.sh` | `toolkit/payload/workflows/required-checks.yml:117`（`bash scripts/sync-labels.sh --dry-run \| tail -1`）、`:194-204`（toolkit 自检）、`:54-56`（`git ls-files '*.sh'` 空集 `exit 1`）。**硬编码假设**：目标仓库就是 pm4gh（有 `scripts/`）；Epic #43 §② 要求 `toolkit/` 含 `scripts/`，但 `manifest.json` 没有登记任何 `scripts/**` | 未 vendor → `ci/test` 明确失败；不 vendor 且无 shell 脚本 → `ci/lint` 明确失败（实测 `git ls-files '*.sh'` = 0） |
| **F3** | **P0 假绿** → [#61](https://github.com/yes8080/pm4gh/issues/61) | 必需检查里的**管道假绿**：`bash scripts/sync-labels.sh --dry-run \| tail -1` 在依赖脚本缺失时**退出码 0**（Actions 默认 shell 为 `bash -e {0}`，**无 `pipefail`**，管道退出码取 `tail`） → "标签定义可解析且格式正确"这一验证**什么都没验** | `toolkit/payload/workflows/required-checks.yml:117` —— 该文件里**唯一**没有 `set -euo pipefail` 的步骤 | 本地 `bash -e step.sh` → 步骤退出码 `0`，stderr 只有 `No such file or directory` |
| **F4** | **P1 语义接管** → [#62](https://github.com/yes8080/pm4gh/issues/62) | 套件向 CODEOWNERS **末尾追加** `* @@OWNER_MENTION@@ @@REVIEWER_MENTION@@`；CODEOWNERS 以**最后匹配**为准 → 用户原有的更早规则（如 `/legacy/ @yes8080`）在**评审归属**上被静默覆盖，与 README「只追加、不重写既有内容」的表述冲突 | `toolkit/manifest.json:323-390`（`objects.codeowners.entries[0]`，`pattern:"*"`）、`toolkit/install.sh:354-384`（追加在文件末尾）。**身份假设**：假定用户 CODEOWNERS 里没有 `*`、也没有更晚的匹配规则 | 对照实验：PR #4 只改 `legacy/notes.md`，由**不在**用户 `/legacy/` 行内的 `reviewer-bot` approve 即满足 `require_code_owner_review`（`mergeStateStatus=UNSTABLE` 而非 `BLOCKED`） |
| **F5** | **P1 工具缺口** → [#63](https://github.com/yes8080/pm4gh/issues/63) | 套件装了 5 个 `status/*` 标签 + `policy/branch-name` 的**状态机闸门**，却**不提供 `scripts/status.sh`**（唯一合法迁移入口）→ 任何采用者的**收尾第 ⑤ 项（关闭后无残留状态标签）必然不通过**，且因 `ci/test` 只扫 OPEN Issue 而**静默漂移** | `toolkit/payload/workflows/required-checks.yml` branch-name job 的 `status/*` 检查；`toolkit/manifest.json` 标签段；`toolkit/` 下没有 `status.sh` | 两次闭环的 Issue（#1、#3）关闭后都残留 `status/in-progress`，人工 `gh issue edit --remove-label` 才收口 |
| **F6** | **P1 首次落地** | `install.sh` 只把文件写进**工作区**、不 commit/push；而 `main-protection` 在**同一轮**就已 active（规则集先于 workflow/CODEOWNERS 处理）且 `bypass_actors=[]` → 装完立刻"受管文件推不上默认分支"，**必须**走一个"自己的门禁由 PR 自身工作流提供"的 bootstrap PR。套件 README 未写这一步 | `toolkit/install.sh:507`（class 顺序 files→labels→rulesets→workflows→codeowners→collaborators）、`toolkit/payload/main-protection.json`（`bypass_actors: []`）。**实测**：同类空 bypass 规则集 `current_user_can_bypass="never"` | 本次被迫自建 bootstrap PR（§4.1），且其首个 SHA 因 F1 而 `BLOCKED` |
| **F7** | P2 凭据布局假设 | `install.sh`/`eject.sh` 默认从**目标仓库根**读 `.secrets/developer.pat` 与 `.secrets/reviewer.pat` —— 这是 pm4gh 的私有约定；目标仓库没有该目录，必须显式传 `DEVELOPER_PAT_FILE`/`REVIEWER_PAT_FILE`（README 参数表只列了 `--author-account`，**没列这两个环境变量**） | `toolkit/install.sh:109-110`（`AUTHOR_PAT="${DEVELOPER_PAT_FILE:-${ROOT}/.secrets/developer.pat}"`）、`toolkit/eject.sh` 同源 | 本次演练必须显式设置这两个变量才能跑 |
| **F8** | P2 空仓库装不上 | 默认分支靠 `gh repo view … --json defaultBranchRef` 探测，**空仓库返回空串** → `die "无法确定默认分支"`；套件也不创建初始提交。PM 的"新建临时仓库"决策因此必须补一步"播种 baseline" | `toolkit/install.sh:98-102` | 本次先由 dispatcher 播了 baseline 提交 `6fe062a` 才能装 |
| **F9** | P2 无工作区守卫 | 文件类对象的比对/写入基准是"**宿主工作区**"，但**不校验当前分支是否为默认分支、工作区是否干净** → 在特性分支或脏工作区上 `install.sh --apply` 会把受管文件写到错误的地方 | `toolkit/README.md` §7 自述基准；`toolkit/install.sh:126`（`target="${ROOT}/${path}"`，无任何分支/洁净检查） | 装机后 `git status` = 1 `M` + 8 未跟踪项，属正常但无护栏 |
| **F10** | P3 恒 UNSTABLE | 非必需审计检查 `qa/acceptance` 在 PR 打开时**必然 fail**（尚无批准），使 `mergeStateStatus` 恒为 `UNSTABLE` 而非 `CLEAN`；pm4gh 的 PLAYBOOK §8 解释了这不是卡点，但**套件 README 没写**，采用者容易误判"PR 被卡" | `toolkit/payload/workflows/acceptance-check.yml`、`toolkit/payload/main-protection.json`（`qa/acceptance` 故意不在必需清单） | 两次闭环 PR 均为 `UNSTABLE` |
| **F11** | P3 设置未纳管 | 套件不管理仓库级设置（`delete_branch_on_merge`、`allow_squash_merge` 等）：目标仓库保持 `allow_merge_commit=true`、`allow_rebase_merge=true`、`delete_branch_on_merge=false`；squash-only 只由规则集 `allowed_merge_methods` 保证，自动删头分支靠 `gh pr merge --delete-branch` 参数 | `toolkit/manifest.json` 无 settings 类对象 | 装机前后 §2.3 的仓库设置比对 |
| **F12** | P3 未触发风险 | `payload/labels.yml` 由 `toolkit/lib.sh` 的**自制 awk** 解析（只认 `name/color/description` 三键、按缩进猜测）；若采用者的 `labels.yml` 含多行 description、引号内冒号等更复杂 YAML，会**静默误读** | `toolkit/lib.sh:115-127`（`parse_label_source`） | **读码发现，本次未触发**（payload 简单）——列出供 PM 决策 |

### 6.1 与 Epic #43 验收标准的对照

| Epic 要求 | 演练结论 |
|---|---|
| `manifest.json` 是唯一归属依据 | ✅ 生效（eject 严格按 ledger 判定） |
| 三态幂等 planned→observed→owned | ✅ 实测（协作者 pending→owned 的 D6 重试语义生效；重复 install 为 no-op） |
| 重复 install 是 no-op | ✅ 实测（0 创建 / 56 一致，退出码 0） |
| 不覆盖、不接管用户既有对象 | ⚠️ **文件/标签/规则集层面成立**；**CODEOWNERS 语义层面不成立**（F4） |
| `eject` 只删 owned 且未漂移；漂移默认保留 | ✅ 实测（0 漂移；dry-run/apply/check 三态一致） |
| tombstone 可中断可续跑 | ✅ 结构落盘、`status=completed`（**未做中断重跑实测**，S1/S2 的 154 条离线断言已覆盖） |
| 卸载后与装机前一致 | ✅ `--check` 退出码 0（59 通过 / 0 失败）；整仓文件树 **逐字节一致** |
| 仓库名/默认分支/身份全部参数化 | ✅ 脚本内无 pm4gh 字符串（`--repo`/`--default-branch`/`--owner`/`--author-account`/`--reviewer-account` 全部生效）；**但 payload 工作流内容仍假设 pm4gh 的 `scripts/`（F2）** |
| 零新增运行时依赖 | ✅ 演练未新增任何依赖或脚本 |

---

## 7. 临时仓库的处置与可恢复证据

### 7.1 可恢复证据（删除前存档）

```text
repo            = yes8080/pm4gh-kit-rehearsal（private，默认分支 main）
created_at      = 2026-10-04T08:15:32Z
deleting_at     = 2026-10-04T08:34:33Z（尝试）
baseline_sha    = 6fe062ab2d0d4df9aee62cd5d5492b15c03e3d23   ← 装机前
final_main_sha  = ac777370288b40f120a39f8f2664417ec99a83f8   ← 卸载落地后（文件树 == baseline）
refs            = refs/heads/main=ac77737
                  refs/pull/2/head=1124cde   （闭环 #1 修复后的头 SHA）
                  refs/pull/4/head=32632da   （闭环 #2）
                  refs/tags/v0.0.1-legacy=6fe062a
删除前对象计数  = labels 11 / rulesets 1 / collaborators 3 / issues 2
```

### 7.2 ⚠️ 未能删除（卡点原文）

```text
$ gh repo delete yes8080/pm4gh-kit-rehearsal --yes
HTTP 403: Must have admin rights to Repository. (https://api.github.com/repos/yes8080/pm4gh-kit-rehearsal)
This API operation needs the "delete_repo" scope. To request it, run:  gh auth refresh -h github.com -s delete_repo
```

- 主身份 `gh` 登录 scope = `gist, project, read:org, repo, workflow` —— **无 `delete_repo`**；
- 两个 bot 的 classic PAT（`repo` [+ `workflow`]）也没有；
- **过渡处置**：已把仓库置为 **archived（只读）**（`gh repo archive` 可用 `repo` scope 完成），避免被误用；
- **完成删除需要**（二者其一）：
  1. 用带 `delete_repo` 的凭据执行 `gh repo delete yes8080/pm4gh-kit-rehearsal --yes`；
  2. 网页 Settings → Danger Zone → Delete this repository（仓库名 `pm4gh-kit-rehearsal`）。
- 仓库内**不含任何凭据**；内容为上述演练证据 + 已还原为 baseline 的样例项目。

> 这也是本切片给 PLAYBOOK §9「人工步骤清单」带来的新条目：**"用完即删"的仓库清理不能假定凭据可删仓**。

---

## 8. 文档是否够用 / 卡点 / 偏离文档的决定

### 8.1 文档够用度

| 场景 | 判定 |
|---|---|
| pm4gh 侧主流程（`start/deliver/review/merge/closeout`） | ✅ 够用：W0.4 身份开通四步可照抄执行（邀请 → 接受 → 回读），本次三身份结构一次成型 |
| 目标仓库侧（本切片的真正主题） | ⚠️ **不够用**：①install 后如何把受管文件弄上默认分支（bootstrap PR）无文档（F6）；②`ledger` 是否入库无文档（F1）；③目标仓库无 `scripts/status.sh` 时如何收尾无文档（F5）；④`DEVELOPER_PAT_FILE`/`REVIEWER_PAT_FILE` 两个必需环境变量未进 README 参数表（F7） |
| 环境陷阱 | ✅ 既有 §4 全部命中且有效（bash 3.2 写法、`gh` 能力边界、必需检查"新 SHA 新结论"） |

**新踩到、已写入 PLAYBOOK §4 的坑**（本次 PR 内）：

1. 套件自带的**运行时 ledger 与分发物同文件** → 真用一次即弄红 `ci/test`（F1，→ #60）；
2. Actions `run:` 默认 shell **无 `pipefail`** → `外部脚本 | tail` 会**假绿**（F3，→ #61）；
3. **CODEOWNERS 以最后匹配为准** → 追加 `*` 会语义接管用户原有规则（F4，→ #62）；
4. **`gh run view --log-failed` 在受限沙箱里会因写 `~/.cache/gh` 失败** → 用 `XDG_CACHE_HOME=<可写目录>`；
5. **`gh repo delete` 需要 `delete_repo` scope**，默认登录与 `repo[+workflow]` PAT 都没有（→ §9 人工步骤）；
6. **macOS 无 `timeout`**：长命令不要用 `timeout`，用后台作业 + 轮询。

### 8.2 卡点原文（汇总）

```text
[卡点 1｜F1，已解] ci/test 首个子提交必红：
  [FAIL] T0.1 toolkit/ 内无 yes8080（期望 ；实际 …/toolkit/manifest.json:781: "collaborator:yes8080-dev-bot": { …
  自检结果：PASS=141 FAIL=13
  ##[error]toolkit 自检失败（退出码 1）—— 详见上方 [FAIL] 行
  → 通过"新 SHA + manifest 出厂状态入库"解除（未绕过门禁）

[卡点 2｜F5，未解] 收尾第 ⑤ 项：
  关闭后残留 status/*: 'status/in-progress'   ← 套件未提供 scripts/status.sh

[卡点 3｜环境，未解] 删除临时仓库：
  HTTP 403: Must have admin rights to Repository.
  This API operation needs the "delete_repo" scope.
```

### 8.3 偏离文档 / 自主决定的记录（须 PM 追认）

| # | 偏离 | 原因 | 影响 |
|---|---|---|---|
| 1 | 临时仓库**未删除**，改为 archived 只读 | 现有凭据无 `delete_repo`（卡点 3） | 违反 PM 决策 1 的"用完必须删掉"；需 PM/人工补删 |
| 2 | 让闭环通过的做法：`toolkit/manifest.json` **以出厂状态入库**，本机另存带 ledger 的副本 | 文档未规定 ledger 是否入库；入库脏状态必然弄红 `ci/test`（F1） | 该"绕法"本身就是 F1 的证据；不应作为推荐做法 |
| 3 | 受管文件落地（commit/push）用**作者身份**，而 `install.sh` 自身用 dispatcher（admin） | 与 PM 决策 2 一致（admin 动作 vs 文件改动）；W0.4 亦要求规则集/协作者由 admin 执行 | 无 |
| 4 | 卸载结果**直推 `main`**（非 PR） | `eject.sh` 按设计先删 `main-protection`，默认分支已无门禁；且这是唯一可行顺序 | 无门禁保护下的清理提交；F6 同类问题的延伸 |
| 5 | 闭环用的业务改动（`legacy/notes.md`）在卸载后**还原**为 baseline | 让"整仓文件树逐字节一致"成为可判定的零损伤证明 | 无（闭环证据已在 §4 留存） |
| 6 | 把与 PM 已开的 #60 重复的 Bug #59 **关闭并指向 #60** | 避免同一缺陷两个状态源 | 无 |

---

## 9. 交付物与后续建议

**本切片交付物**
- 本报告 `docs/rehearsal-3-report.md`；
- `docs/PLAYBOOK.md` §4 新增 6 条环境/套件陷阱；
- Bug Issue（已在 pm4gh 建立）：[#60](https://github.com/yes8080/pm4gh/issues/60)（P0，PM 已 Ready 为 `[E2-S3b]`）、[#61](https://github.com/yes8080/pm4gh/issues/61)（P0）、[#62](https://github.com/yes8080/pm4gh/issues/62)（P1）、[#63](https://github.com/yes8080/pm4gh/issues/63)（P1）；#59 已作为 #60 的重复关闭。

**建议 PM 的下一步（按优先级）**
1. **先解 #60 + #61**（二者耦合：不 vendor 则 `ci/test` 缺失即失败，vendor 则 ledger 弄红自检）——否则任何"真装"都落地不了；
2. #62/#63 可随 E2-S4「策略开关」一并处理（都属"装到别人仓库后的语义"）；
3. **处置临时仓库**：`yes8080/pm4gh-kit-rehearsal` 需删除（当前 archived）；
4. 若认可 F6/F7/F8/F9 的价值，建议合并为一个「可移植性硬化」切片（README 补 bootstrap 章节、暴露凭据环境变量、加工作区守卫、支持空仓库）。
