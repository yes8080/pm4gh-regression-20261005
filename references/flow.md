# flow — W0..W8：每步的命令与判据

> **何时读**：开工 / 交付 / 返修 / 合并收尾时翻对应小节。身份见 [identity.md](identity.md)，迁移见 [status-machine.md](status-machine.md)，异常见 [traps.md](traps.md)。

## 前置约定

- 命令一律在**仓库根目录**执行（`gh` 不带 `-R`）；占位符 `<n>` / `<pr#>` 只填**数字**（不带 `#`，脚本会拒绝）。
- 与平台实际行为冲突时以**平台**为准；**必须**开 Issue 改文档，**禁止**按"更方便"执行。
- `--dry-run`（`start.sh` / `deliver.sh` / `closeout.sh` / `abort.sh` 支持；其余脚本无）= 不建分支、不推送、不建 PR、不写 Issue、不删分支、不迁移状态；`closeout.sh --dry-run` 仍判五项，判不过退出码 `1`。**例外**：`deliver.sh --prepare --dry-run` 仍会写正文骨架文件（`cat >` 在 `--dry-run` 判断之前执行）。
- **项目测试套件约定（唯一一套）**：项目在 `tests/run.sh` 声明**自己交付物**的测试套件，**`exit 0` = 通过**、非零 = 失败。`ci/test` 的「项目自身测试套件」step 会运行它，`preflight.sh` 第 3 段断言入口存在且可执行。`tests/` 不存在 = 本项目未声明测试套件 —— 两处都**明确打印**「已运行」/「未声明」，**不允许**静默跳过；有 `tests/` 却没有合法 `tests/run.sh`（缺失 / 无 `x` 位）则 CI 与预检都 `[FAIL]`。边界：**删掉 `tests/` 与「本项目确实没有测试」在门禁看来完全一样**（没有声明文件就无法区分），绕过这条等于承诺"本项目不声明测试"。

## 时序步骤表（谁在什么时候触发）

| # | 角色 | 动作 | 产物 / 门禁 | 失败·返修 |
|---|---|---|---|---|
| 1 | 作者（agent） | 拆片 + 建 Issue：**作者身份**，DoR 五项齐备（规则见 [SKILL.md](../SKILL.md)「切片拆分与分发」W0.5） | Issue（W1）；建单后停 `backlog`（OPEN 且无 `status/*`） | DoR 不齐 → 留在 `backlog` 补齐；**目标本身**有歧义 → 问 Issue 作者 / dispatcher（[exceptions.md](exceptions.md) 第 5 条） |
| 2 | dev-bot | W2 `scripts/start.sh <issue#> --as author` | 分支 `<type>/<issue#>-<slug>`；状态 `in-progress`（W0 全过） | 只读状态预检非法 → **建分支之前**失败 |
| 3 | dev-bot | W3 实现 + 提交（作者身份，`commit -F`） | 提交；工作区干净；`bash -n scripts/*.sh` 通过 | 语法 / bash 3.2 失败 → 先修 |
| 4 | dev-bot | W4 `scripts/deliver.sh <issue#> --as author` | PR 正文含 `Closes #N` + 六段；状态 `in-review` | 缺 `Closes #N` / 六段 → 推送前失败 |
| 5 | CI/规则集 | W5 `gh pr checks <pr#> --required`（PR 事件自动触发） | 5 个必需检查全 `pass` | 任一失败 → 修后同分支再推（走 #7） |
| 6 | reviewer-bot | W6 `scripts/review.sh <pr#> approve --body-file <文件>`（**不加** `--as`；禁止自批） | `reviewDecision=APPROVED` → 停在 `in-review` | `request-changes` → 状态 `in-progress`（同分支返修） |
| 7 | dev-bot | 返修：**同一分支**继续提交（不新建分支 / PR）后 `deliver.sh` 再推 | 新 SHA；必需检查在新 SHA 重跑；回到 `in-review` | `require_last_push_approval` 驳回旧批准 → **必须**回 #6 重评 |
| 8 | dispatcher | W7 `gh pr merge <pr#> --squash --delete-branch`（只有 `@yes8080` 能做） | Issue 自动关单 → 状态 `done` | 缺批准 / 必需检查未过 → 合并被拒 |
| 9 | dispatcher | `scripts/closeout.sh <pr#>` 五项核验 | 见 W7 | 任一项不过 → 贴原文报告 |

> 顺序之外只有 W8：异常路径出口 → `scripts/abort.sh <issue#>` → `canceled`。

## W0 预检（每次接手都跑）— `scripts/preflight.sh`

- **判据**：无参数；全 `[ OK ]` 且退出码 `0`；任一 `[FAIL]` → 退出码 `1`，**禁止**"先干着看"，把失败项**原文**贴 dispatcher。
- 输出 `1/10`…`10/10` 十组：① 命令齐备 ② gh 登录 ③ 仓库形态与 cwd ④ 工作区与远端 ⑤ 三身份凭据 ⑥ 作者凭据 scope 与最小权限 ⑦ 工作流 job 名 == 必需 context ⑧ 线上规则集整份 diff + **CODEOWNERS 完整性**（每个 owner 是协作者且有 push / 评审身份是 `*` 的 owner / 合并身份是协作者 —— 防 `require_code_owner_review` 永久锁死；开关取值只认线上实测值）⑨ 机器消费 + **Issue 表单预置**标签存在（表单标签从 `.github/ISSUE_TEMPLATE/*.yml` 解析，不手抄）⑩ 工作区内无 `*.pat`。组③还含 **项目测试套件接线**（`tests/` 存在 → `tests/run.sh` 必须存在且可执行；判据用仓库根绝对路径，cwd 是子目录也准）与 **R1 单写者锁**（本 clone 若已被另一个**存活**写者占用 → `[FAIL]`；陈旧锁**自动接管并打印原因**；锁在**工作区之外**）。组④还含 **R2 分支归属**（当前分支必须是某个 `status/in-progress` Issue 的分支；**基线分支上显式不适用**并打印「未执行」）与 **R3 在途切片数**。**并发模型**（1 clone = 1 写者 = 1 Issue；并行 = 各自独立 clone）见 [orchestration.md](orchestration.md) §7。
- **判据**：只有 `[FAIL]` 计入失败，`[WARN]` 一律不阻断（退出码仍 `0`）。常见 `[WARN]`：工作区有未提交改动、本地 `main` 与 `origin/main` 不一致、无法 fetch、评审凭据缺失、作者权限异常、**超过一个 `in-progress`**（并行**允许** —— 前提是各自独立 clone；同一 clone 内仍一次只做一个切片）、默认锁目录不可写时回退到 `/tmp/pm4gh-locks-<uid>`、基线分支上 R2 未执行。组⑦⑧需要 `.github/workflows/*.yml` 存在 —— 在**没有**工作流的副本里跑必然 `[FAIL]`，这是环境事实，不是流程失败。
- **新增的两条 `[FAIL]` 与修法**：① `本 clone 已被另一个写者占用` → **停下**：要并行就**另开独立 clone**并在新 clone 里用**自己的 Issue**（不要抢锁、不要切别人的分支）；确认原写者已退出后重跑（陈旧锁会被自动接管并打印原因）。② 当前分支不是任何 `status/in-progress` Issue 的分支（含游离 HEAD / 非切片分支形态）→ 先确认本 clone 归属哪个 Issue，用 `scripts/start.sh <issue#> --as author` 建分支开工，或换到正确分支（**禁止**手工 `git checkout -b`）。两条都**不得**通过删判据 / 改门禁绕过。

## W1 领片（DoR）

`gh issue list --state open --label status/ready --limit 20 --json number,title,labels` → 只读判定 `scripts/status.sh --check-transition backlog ready`（退出码 `0` = 合法）→ `scripts/status.sh <n> ready --as author`。

- **判据**（五项全齐才可 `backlog → ready`）：① 价值一句话 ② 可判定的验收标准 ③ 明确不改什么（边界）④ 依赖与契约 ⑤ 规模与执行者。
- **建单不是 W1**：切片 Issue 由**作者身份**在拆片时建好（[SKILL.md](../SKILL.md)「切片拆分与分发」W0.5），建完停在 `backlog`；`ready` 只表示「DoR 齐备、可被领取」，**不是**建单的必经步骤（`backlog → in-progress` 是合法边）。

## W2 开工 — `scripts/start.sh <issue#> --as author`（线上故障加 `--type hotfix`）

- **判据**：退出码 `0`（`1` 校验或迁移失败 / `2` 参数错）；分支 `<type>/<issue#>-<slug>` 由 `gh issue develop` 创建并**绑定** Issue；Issue 已指派给作者；开工声明评论已提交；状态 `in-progress`。
- **禁止**：手工 `git checkout -b`（不建立 Issue 绑定）；假定 Issue 停在 `backlog`（脚本读平台当前状态）；**返修不走这里**（在原分支继续提交）。非法当前状态（例如 `in-review`）→ **在创建分支之前**失败，不留半成品。
- `type ∈ {slice,fix,hotfix,spike,chore}`；slug 从标题推导（`[a-z0-9-]`，**没有覆盖开关**）。不给 `--type` 时按标签推导：`type/hotfix`→`hotfix`、`type/bug`→`fix`、`type/spike`→`spike`、`type/chore`→`chore`，其余→`slice`。
- **线上故障必须显式 `--type hotfix`**（显式优先于标签）：Issue 表单的下拉**不会**打标签，漏打会让热修**静默**退化成 `fix/`；推导为 `fix` 时脚本打印 `[WARN]`，**必须**复核（[traps.md](traps.md) 陷阱 12）。`policy/branch-name` 逐字校验 `^(slice|fix|hotfix|spike|chore)/[0-9]+-[a-z0-9-]+$`，并要求 Issue OPEN 且已有 `status/*` 标签。

## W3 实现与提交

```bash
git add -A && bash -n scripts/*.sh && scripts/status.sh --check
git -c user.name="yes8080-dev-bot" -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" commit -F <消息文件>
```

- **判据**：`bash -n scripts/*.sh` 与 `scripts/status.sh --check` 退出码均 `0`。
- **必须**：提交者身份显式指定（`--as author` 只切 `gh` 的 API 身份，**不改** git 身份）；提交信息用 `-F <文件>`（反引号 / 多行内联进命令行会被 shell 吃掉）；`deliver.sh` 之前工作区**干净**（有未提交改动时直接失败）；bash 3.2 兼容（[traps.md](traps.md) 陷阱 7）。

## W4 交付 PR — `scripts/deliver.sh <issue#> --prepare --as author` → 填六段 → `scripts/deliver.sh <issue#> --as author`

- **判据**：退出码 `0`；正文含 `Closes #N`（**PR 标题里的关键字无效**）与 `## 1.`…`## 6.` 六段（每段非空白字符 ≥ 20）；分支名合规且分支里的 issue 号 = 传入的 issue 号；工作区干净；推送成功；PR 已建或正文已更新并**回读一致**；状态 `in-review`。
- **必须**：脚本先跑 `status.sh --check-transition <cur> in-review` —— 非法则**在推送之前**失败，不写骨架、不推送、不建 PR。
- 骨架默认 `.git/PR_BODY_<issue#>.md`；用 `--prepare --body-file <文件>` 换路径后，**最终那条命令也要带同一个** `--body-file <文件>`；PR 标题由脚本生成 = `<Issue 标题> (#<issue#>)`，**禁止**改标题。
- 该分支**已有** PR（返修）时只推送并改用 REST PATCH 更新正文（脚本已封装 + 回读校验）；**禁止** `gh pr edit` 改正文（[traps.md](traps.md) 陷阱 5）。当前状态为 `backlog` / `ready` → 先 `scripts/start.sh <issue#> --as author`。

## W5 必需检查（5 个，逐字）— `gh pr checks <pr#> --required`

| context（= job `name:`） | 判什么 |
|---|---|
| `ci/lint` | 被跟踪脚本的 `bash -n` + bash 3.2 兼容 + JSON 有效 |
| `ci/test` | 5 个 context 与工作流 job 名精确相等、规则集形状与全量键、状态标签互斥、状态迁移 HTTP 层单请求（stub `gh` + 反向样本）、PR 模板六段、无凭据入库、脚本自包含、`status-machine.md` ↔ `status.sh` 转换表逐字一致、**项目自身测试套件 `tests/run.sh`**（有 `tests/` 就必跑，`exit 0` = 通过；无 `tests/` 打印「未声明」） |
| `policy/linked-issue` | 正文有 `Closes #N` **且** GitHub 解析出了关闭关系（目标必须是默认分支） |
| `policy/branch-name` | 分支名匹配正则 + Issue OPEN + 已有 `status/*` 标签 |
| `policy/template` | 正文有 `## 1.` … `## 6.` |

- **判据**：5 个 context 在**最新 SHA** 上全 `pass` 才进 W6；某项永久 `pending` → [traps.md](traps.md) 陷阱 1、2。
- **`ci/test` 的项目测试 step**（约定见「前置约定」）：`tests/` 存在且 `tests/run.sh` 可执行 → 运行它、把**原始输出尾部**打进日志；退出码非零 → `ci/test` FAIL。`tests/` 存在但 `run.sh` 缺失 / 无 `x` 位 → FAIL（修法：`chmod +x tests/run.sh`）。无 `tests/` → 打印 `[ OK ] 本项目未声明测试套件（…）` 再跳过 —— **必须**打印，禁止静默跳过。

## W6 独立评审 — `scripts/review.sh <pr#> approve --body-file <文件>`（评审身份，**不加** `--as`；动作取值 `approve` / `request-changes` / `comment`）

- **判据**：退出码 `0` 发出评审 / `1` 校验或认证失败 / `2` 参数错（用法、编号、动作、缺评审意见）；`approve` → `reviewDecision=APPROVED`；`request-changes` → 平台 `CHANGES_REQUESTED`。
- **必须**：由 `@yes8080-reviewer-bot` 发；approve / request-changes 必须给 `-m <文本>` 或 `--body-file <文件>` 之一（同时给时 `-m` 优先）；`review.md` 只是示例文件名，路径由调用者决定。**禁止**自批（作者批准自己的 PR）、评审身份合并。
- `approve` **不迁移状态**（停在 `in-review`）；`request-changes` 时若分支里的 issue 号在 PR 的 `closingIssuesReferences` 中，脚本自动 `scripts/status.sh <n> in-progress --as reviewer`（打印 `[WARN] 跳过状态迁移` 时**必须**人工补）。
- **判据**：返修后新推送**驳回旧批准**（`require_last_push_approval`）→ **必须**回 W6 重评。门禁读数：`gh pr view <pr#> --json reviewDecision,mergeStateStatus`。

## W7 合并与收尾（dispatcher）

`gh pr merge <pr#> --squash --delete-branch` → `scripts/closeout.sh <pr#>`。

- **判据**：`closeout.sh` 五项全过且退出码 `0`（用法 / 编号错 → `2`）：① PR 已 MERGED ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地头分支已清理 ⑤ 无残留 `status/*` 标签。任一不过 → 退出码 `1`，逐条贴原文报告。五项全过时**同时释放本 clone 的单写者锁**（R4，见 [orchestration.md](orchestration.md) §7；`--dry-run` 不释放）。
- **禁止**：作者代跑合并；`gh pr merge --admin` 或任何绕过门禁的手段 —— 只有 `@yes8080` 用本机登录态合并。
- 第 ⑤ 项由 `closeout.sh` 自己跑 `scripts/status.sh <n> done --as dispatcher`（**仅对已关闭的 Issue**，OPEN 的绝不代关）；第 ④ 项**先**把「分支名 + 本地 tip SHA + PR head SHA + squash 提交」写进 Issue 作可恢复锚点，**再** `git branch -D`（[traps.md](traps.md) 陷阱 9）。

## W8 终止/取消（异常路径出口）— `scripts/abort.sh <issue#>`

**触发者**：谁决定终止都可以（作者 / 人·PM / dispatcher），但**执行本命令的只能是作者身份**（`--as` 只接受 `author`，默认即 `author`）。先 `--dry-run` 看它要删什么；自动发现不到分支时显式 `--branch <分支名>`；内容已另有归宿用 `--evidence "<说明>"`；附原因用 `--reason "<原因>"`。

- **必须**：`--reason` / `--evidence` 不带 tab / 换行 / `|`（脚本会替换成空格后写进锚点）；清理**本地 + 远端**分支；状态 → `canceled`（**只走 `scripts/status.sh`**）；在 Issue 留可恢复锚点（分支 tip SHA / 原因 / 时间 / 判据）。
- **判据**（全部成立才终止）：① 不再计划完成 ② 删除分支**不会丢内容**。删除判据（fail-closed）三条任一成立才删：① 分支 tip（本地与远端都算）是 `origin/main` 的**祖先** ② 该分支有**已合并**的 PR ③ 显式 `--evidence "<说明>"`。
- **违反后果**：三条都不成立（存在独有未合并提交）→ **一个分支都不删、状态也不迁移**，打印分支 tip、独有提交与处置选项后退出 `1`；锚点写不进去同样不删。
- **判据**：退出码 `0` 已清理 / 幂等无操作；`1` 拒绝删除或迁移失败；`2` 用法错。**幂等**：连跑两次，第二次零写操作。`done` 是终态且属合并收尾 → `abort.sh` **拒绝**处理，走 `closeout.sh`；确需取消先 `gh issue reopen`。异常路径闭环（含幂等无操作）时**同时释放本 clone 的单写者锁**（R4，见 [orchestration.md](orchestration.md) §7；`--dry-run` 不释放）。
