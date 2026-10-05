# bootstrap-checklist — 新项目启动清单（把本流程落到**另一个仓库**时逐条抄一遍）

> **何时读**：在**新仓库**（或从零）落地本治理时 —— 每次只读本文件、逐条打勾。
> 本仓库日常推进（W0..W8）**不需要**读它。
> **口径**：本文件是**索引 + 打勾表**，不是第二套规范 ——
> 每条规则的**正文只在它的权威文件里**（[traps.md](traps.md) / [portability.md](portability.md) / `scripts/preflight.sh`）。
> **禁止**把规则正文复写到本文件（复写 = 同一事实两处载体，必然漂移）。
> 本表的**覆盖度**由 `ci/test` 的「文档命令可执行性 + 启动清单全量覆盖」判据断言（见 §5 机器可读索引）。

## 0. 三步落地（顺序不能换）

1. **复制**：目标仓库根目录放 `SKILL.md` + `references/**` + `.github/**` + `scripts/**`（clone 或复制）。
2. **替换**：按 §2 的 **11 条**逐一替换（细节与机器判据见 [portability.md](portability.md) §1）。
3. **验收**：在目标仓库根目录跑 `scripts/preflight.sh`（无参数）：全 `[ OK ]` 才算装好；
   `[FAIL]` 会直接说出哪条链接 / 标签 / 凭据 / owner 没改 —— **不要靠记忆，靠预检**。

## 1. 平台陷阱（[traps.md](traps.md) **全量 21 条**）

打勾 = 已确认目标仓库不会踩，或已被某条机器判据兜住。**规则正文只在 traps.md**，本表只是索引。

| ☐ | # | 索引关键词 | ☐ | # | 索引关键词 |
|---|---|---|---|---|---|
| ☐ | 1 | 必需检查不能"先失败后通过" | ☐ | 11 | tab 当字段分隔符会静默吞掉空字段 |
| ☐ | 2 | 必需检查 context = job 的 `name:` | ☐ | 12 | Issue 表单不会打标签（`type/hotfix` 热修静默退化） |
| ☐ | 3 | 规则集只能整份比对 / 只用 `~DEFAULT_BRANCH` | ☐ | 13 | 凭据隔离的能力边界（文件隔离 ≠ 防线） |
| ☐ | 4 | 每个会被改动的路径要有"非作者" owner | ☐ | 14 | `pipefail` 下禁止 `printf … \| grep -q`（EPIPE） |
| ☐ | 5 | 作者 PAT 只有 `repo` + `workflow`（无 `read:org`） | ☐ | 15 | macOS bash 3.2.57 的 `read -t 0` 不可用 |
| ☐ | 6 | 推送必须清掉本地 credential helper | ☐ | 16 | `gh issue create -T` 在非交互下不可用 |
| ☐ | 7 | macOS 自带 bash 是 3.2（禁 bash4 特性） | ☐ | 17 | `NL="$(printf '\n')"` 得空串 → 反向样本退化 |
| ☐ | 8 | `blockedBy` 不因对方关闭而自动清除 | ☐ | 18 | 字节级往返不能用 `$()` / `jq -r`（尾换行） |
| ☐ | 9 | squash 合并后 `git branch -d` 必然拒绝 | ☐ | 19 | 依赖 slug / 身份 / 线上值的断言必须 fail-closed |
| ☐ | 10 | 状态迁移判据是「HTTP 层单请求」 | ☐ | 20 | 标题行判据是 ATX 形态（`^#{1,6}[[:space:]]`），不是 `^#` |
| ☐ | 21 | 需长期准确的引用写**符号锚点**，不写 `file:line`（两份清单零命中） |  |  |  |

## 2. 替换点（[portability.md](portability.md) §1 **全量 11 条**）

| ☐ | # | 替换点 | 机器判据 |
|---|---|---|---|
| ☐ | 1 | 仓库 slug（`.github/ISSUE_TEMPLATE/config.yml` 里的 URL） | ✅ preflight 第 8 段 P6 链接断言 |
| ☐ | 2 | 三身份用户名（作者 / 评审 / 合并） | ✅ 部分（第 5/8 段；模板展示名无判据） |
| ☐ | 3 | 作者 git 身份（提交署名） | ❌ 无（人工确认） |
| ☐ | 4 | 凭据路径（优先用 `DEVELOPER_PAT_FILE` / `REVIEWER_PAT_FILE`） | ✅ 第 5 段（工作区之外 / 600 / 未入库） |
| ☐ | 5 | CODEOWNERS owner 列表 | ✅ 第 8 段（协作者 + push + `*` owner） |
| ☐ | 6 | `ISSUE_TEMPLATE/config.yml` 的 contact 链接 | ✅ 同 #1（P6） |
| ☐ | 7 | `SKILL.md` 安装路径（已是相对当前仓库写法） | ❌ 无（人工核对绝对路径零命中） |
| ☐ | 8 | 测试床 / 绝对路径引用（stub slug、登录名） | ❌ 无（stub 值不参与断言） |
| ☐ | 9 | 流程标签体系（`status/*` ×3 + `type/*` ×4 + 表单 `labels:`）**与表单完整性**（每张表单都含 DoR 五项 label、至少一张含缺陷证据字段集；`.github/ISSUE_TEMPLATE/` 必须存在） | ✅ 第 9 段（`LABEL_ASSERT` + `DOR_ASSERT`，与 `ci/test` 逐字一致 + 动态枚举） |
| ☐ | 10 | 门禁接线（规则集 + 5 个必需检查 job `name:` 一字不改） | ✅ 第 7/8 段 |
| ☐ | 11 | 项目测试套件入口（`tests/run.sh`；没有测试就**别建** `tests/`） | ✅ `ci/test` 项目测试 step + 第 3 段 |

## 3. 治理假设（`scripts/preflight.sh` 会断言的 **10 段**）

每段都是目标仓库**必须成立**的假设；任何一段 `[FAIL]` 都说明落地没完成（不要靠"应该没事"）。

| ☐ | 段 | 假设 |
|---|---|---|
| ☐ | 1 | 基础命令齐备（`git` / `gh` / `jq` / `awk` / `grep` / `sed` / `curl` / `diff`），bash 3.2 可跑 |
| ☐ | 2 | `gh` 已登录（合并身份 = dispatcher），且登录身份 ≠ 作者身份 |
| ☐ | 3 | 在仓库根目录、非 worktree、仅一个 worktree、无 `index.lock`；`gh repo view` 能解析出 slug；**本 clone 的单写者锁**已获取或已接管陈旧锁（锁在**工作区之外**，默认 `$HOME/.config/pm4gh/locks`，不可写时回退并打印原因） |
| ☐ | 4 | 远端只有 `origin`；本地与 `origin` 的默认分支一致（不一致只是 `[WARN]`）；**R2** 当前分支归属一个**在途** Issue（`status/in-progress` 或 `status/in-review`——交付后待评审也算在途；基线分支上显式未执行）；**R3** 在途 `in-progress` > 1 只是 `[WARN]`（并行 = 各自独立 clone） |
| ☐ | 5 | 作者凭据在**工作区之外**、权限 `600`、未入库；工作区内**没有任何** `*.pat` |
| ☐ | 6 | 作者凭据 scope 含 `repo` + `workflow`，且作者对本仓库有 push、无 admin |
| ☐ | 7 | 工作流产出的检查名与 5 个必需 context **精确一致**（改名 = 所有 PR 永久 pending） |
| ☐ | 8 | 线上规则集与仓库内定义**整份一致**；CODEOWNERS owner 有 push、评审身份是 `*` owner、合并身份是协作者 |
| ☐ | 9 | 机器消费（`status/*` ×3 + `type/*` ×4）与 Issue 表单预置的标签**都存在**；且**每张** Issue 表单都含 DoR 五项 label（逐字）、**至少一张**含完整缺陷证据字段集（复现步骤 / 期望 vs 实际 / 影响版本 / 证据 / 回滚·临时缓解）；`.github/ISSUE_TEMPLATE/` 目录必须存在 |
| ☐ | 10 | 仓库里没有凭据被提交 |

## 4. 落地完成的判据（可复核，逐条给证据）

- [ ] `scripts/preflight.sh` 全 `[ OK ]`、退出码 `0`（**唯一**的"装好了"判据）。
- [ ] 目标仓库的 PR 上 `ci/lint` + `ci/test` 通过（5 个必需检查 context 与 job `name:` **一字不改**）。
- [ ] 规则集已在平台上建好且与 `.github/rulesets/main-protection.json` 一致（第 8 段）。
- [ ] 用 Issue 表单**真的建过一张单**（验证表单预置标签存在；表单指向不存在的标签会当场失败），且两张表单都能给出 DoR 五项 —— 缺陷表单还要带齐复现 / 证据字段（判据 `DOR_ASSERT`，第 9 段）。
- [ ] 文档里的命令形态与脚本参数解析一致（`ci/test` 的「文档命令可执行性」判据；判据本身靠脚本的 `--parse-only` 零副作用解析路径）。
- [ ] ❌ **反例（跑不了，别照抄）**：`scripts/status.sh 144 in-progress`（缺 `--as` → fail-closed 拒绝；见 [flow.md](flow.md)）<!-- 非可执行示例 -->

## 5. 机器可读索引（`ci/test` 断言：与三份权威清单**逐条**对齐）

<!-- BOOTSTRAP_COVERAGE:BEGIN —— 覆盖度索引；改 traps.md / preflight.sh / portability.md 的条目后必须同步本区 -->
traps=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21
preflight=1,2,3,4,5,6,7,8,9,10
portability=1,2,3,4,5,6,7,8,9,10,11
<!-- BOOTSTRAP_COVERAGE:END -->

> 新增 / 删除一条陷阱、一段预检或一个替换点后，**必须**同步本区的编号：
> 少了号 → `ci/test` 报 `[FAIL]` 并指出漏了哪个（防"清单悄悄过期"）。

## 6. 新判据检查项（**每条新判据合入前**逐条打勾）

> 规则正文只在 [exceptions.md](exceptions.md) §7（判据的假红防线）；本表只是索引，**禁止**在此复写规则正文。
> **为什么单列**：判据**自身**的缺陷（假红）不会被判据抓到 —— 只能靠"在**全部合法流程状态**下各跑一遍"。

| ☐ | 检查项 | 判据 / 落点 |
|---|---|---|
| ☐ | 新判据在**全部合法流程状态**下验证不假红：开工前 / 实现中 / **交付后待评审（in-review）** / 返修中 / 终止后 / 被别人切走 | 六态**逐项**真实输出 |
| ☐ | 给出「**另一侧**」证据：合法情形**不被拦**（**不能只有 FAIL 样本**） | 每条合法状态一行真实输出 |
| ☐ | 给出**改前对照**：同一输入在修复（或合入）**之前**的真实输出 | 基线 SHA 上跑同一输入 |
| ☐ | 「读不到判定输入」**不当作异常**：显式未执行（`[WARN]` / `[ SKIP ]`）或按宽容侧处理并打印原因 | [exceptions.md](exceptions.md) §7.3 |
| ☐ | 配套**反向样本**（改坏 → 必须 FAIL），证明放宽假红后**不假绿** | [exceptions.md](exceptions.md) §4.4 |
