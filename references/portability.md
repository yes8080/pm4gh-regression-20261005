# portability — 采用者替换点清单（把本 skill 装到**另一个仓库**）

> **何时读**：要把本流程用于**另一个仓库**时。本仓库日常推进**不需要**读本文件。
> 口径：本 skill 面向**已就绪**仓库的日常推进，「从零建成一套治理」不在它的执行范围内 ——
> 但「建成」需要改的东西就是下面这张清单，逐条替换完即在目标仓库就绪。

**做法**：在目标仓库里放 `SKILL.md` + `references/**` + `.github/**` + `scripts/**`（clone 或复制），
按 §1 逐条替换，然后在**目标仓库根目录**跑 `scripts/preflight.sh`：全 `[ OK ]` 才算装好。
`[FAIL]` 会直接说出哪处链接 / 标签 / 凭据 / owner 没改 —— 不要靠记忆，靠预检。

## 1. 替换点（每条：在哪 `file:line` → 换成什么 → 是否有机器判据）

| # | 替换点 | 在哪（`file:line`） | 换成什么 | 机器判据 |
|---|---|---|---|---|
| 1 | **仓库 slug** | `.github/ISSUE_TEMPLATE/config.yml:6,9,12`（`https://github.com/<owner>/<repo>/blob/main/…`） | 目标仓库的 `<owner>/<repo>` | ✅ `preflight.sh` 第 8 段 **P6 链接断言**：`.github/` 内 `github.com/<owner>/<repo>` ≠ 当前 slug（`gh repo view`）→ `[FAIL]` 并逐条列出。slug 本身不写死 |
| 2 | **三身份用户名** | 作者 `@<author-bot>`：`references/identity.md:9`、`.github/CODEOWNERS:9,10,12,17`、`.github/ISSUE_TEMPLATE/slice.yml:52`、`references/flow.md:51`、`scripts/start.sh:197`；评审 `@<reviewer-bot>`：`references/identity.md:10`、`.github/CODEOWNERS:9,12,17`、`references/flow.md:80`；合并 `@<dispatcher>`：`references/identity.md:11`、`.github/CODEOWNERS:13,17`、`.github/PULL_REQUEST_TEMPLATE.md:56`、`references/flow.md:23,89` | 目标仓库的三个真实账号（作者 ≠ 评审 ≠ 合并） | ✅ 部分 —— 第 8 段从 `references/identity.md:10` 解析**评审身份**并断言「是协作者 + 有 push + 是 `*` 规则 owner」；第 5/8 段断言作者（凭据登录名）与合并（`gh` 登录态）互不相同且是协作者。模板里的展示名无判据 |
| 3 | **作者 git 身份（提交署名）** | `scripts/start.sh:197`（仓库内唯一的署名提示）、`references/flow.md:51`（命令样例） | 作者账号的 `user.name` / `user.email`（`<id>+<login>@users.noreply.github.com`） | ❌ 无 —— 提交署名不参与任何必需检查，人工确认 |
| 4 | **凭据路径** | 默认 `$HOME/.config/pm4gh/{developer,reviewer}.pat`：`SKILL.md:4`、`references/identity.md:9,10,27,33-38`、`scripts/preflight.sh:19,23`、`scripts/start.sh:18`、`scripts/deliver.sh:24`、`scripts/review.sh:21`、`scripts/abort.sh:31` | **优先不改脚本**：用 `DEVELOPER_PAT_FILE` / `REVIEWER_PAT_FILE` 指向目标路径（默认值只是默认） | ✅ 第 5 段：存在 / 权限 `600` / 未被 git 跟踪 / **在工作区之外**（工作区内出现任何 `*.pat` → `[FAIL]`）；`review.sh` 对工作区内路径**拒绝执行** |
| 5 | **CODEOWNERS owner 列表** | `.github/CODEOWNERS:17`（`*  @A @B`）、注释里的三身份 `:9,10,12,13` | 目标仓库的**非作者** owners（评审 + 合并共同拥有；作者不得是任何路径的唯一 owner） | ✅ 第 8 段：每个 owner 是协作者且有 push；评审身份是 `*` 的 owner；合并身份是协作者（`require_code_owner_review` 下防永久锁死） |
| 6 | **`ISSUE_TEMPLATE/config.yml` 链接本身** | `.github/ISSUE_TEMPLATE/config.yml:5-13`（`name` / `url` / `about`） | 指向目标仓库的 `SKILL.md` / `flow.md` / `status-machine.md`；目标仓库不用这些文档时改成中性名称或删掉该条 contact link | ✅ 同 #1（P6）；`about` 文案无判据 |
| 7 | **`SKILL.md` 安装路径** | `SKILL.md:58`、`references/identity.md:19-24` | 已是**相对当前仓库**写法（`ln -s "$(git rev-parse --show-toplevel)"`）→ 通常**无需替换**；只在客户端扫别的目录时改 `~/.agents/skills` / `~/.claude/skills` | ❌ 无（文档命令）。人工核对：`grep -rn '/Users/' $(git ls-files)` 应为零命中 |
| 8 | **测试床 / 绝对路径引用** | `.github/workflows/required-checks.yml:556`（stub `gh repo view` 返回源 slug）、`:571`（stub 作者登录名）；仓库内**不得**再有 `/Users/<you>/…` 绝对路径 | stub 值换成目标仓库 slug / 作者登录名（仅测试夹具，不改也过 CI）；绝对路径换成相对或占位 | ❌ 无（stub 值不参与断言）。人工核对：`grep -rn '/Users/' $(git ls-files)`、`grep -rn 'github.com/' .github/` |
| 9 | **流程标签体系**（目标仓库为空时需先建） | `scripts/preflight.sh:55`（`MACHINE_LABELS`：`status/*` ×3 + `type/*` ×4）+ Issue 表单的 `labels:`（`.github/ISSUE_TEMPLATE/*.yml`） | 在平台上 `gh label create` 建齐同名标签（或改成目标仓库自己的标签名并同步脚本/模板） | ✅ 第 9 段：机器消费 + 表单预置的标签必须都存在（判据与 `ci/test` 逐字一致，带反向样本） |
| 10 | **门禁接线**（规则集 / 必需检查名） | `.github/rulesets/main-protection.json`、5 个必需检查的 job `name:`（`.github/workflows/required-checks.yml:26,104,1679,1709,1743`） | 在目标仓库建同名规则集；`name:` **一字不改**（改名 = 所有 PR 永久 pending） | ✅ 第 7 段（job `name:` 与 5 个必需 context 逐字一致）+ 第 8 段（线上规则集整份 diff，全量键） |
| 11 | **项目测试套件入口**（采用者若已有测试，放这里即**自动接入**门禁） | `tests/run.sh`（目标仓库里通常**还不存在**；本仓库本身也没有 = 未声明测试套件） | 把已有的测试入口放到 `tests/run.sh`（`exit 0` = 通过，非零 = 失败）并 `chmod +x tests/run.sh`。**没有测试就不要建 `tests/`** —— 无 `tests/` 即「未声明」，两处都打印说明行 | ✅ `ci/test`「项目自身测试套件」step（有则**运行**它；缺入口 / 无 `x` 位 → FAIL）+ `preflight.sh` 第 3 段（有 `tests/` → 入口必须存在且可执行）。**无需**改规则集 / 5 个 job `name:` |

## 2. 已知取舍

- **P6 判据不猜意图**：`.github/` 里指向**第三方**仓库的 `github.com/…` 链接同样会被判不一致。确需引用第三方时写成不含 `github.com/` 的 `owner/repo` 文本，或报告 dispatcher 说明。
- **`references/identity.md:10` 是评审身份的机器可读载体**：第 8 段从那张表解析评审用户名，改表 ≠ 改得对 —— 必须同时是目标仓库的协作者且有 push，否则 `preflight.sh` 报 `[FAIL]`。
- **本文件自身不含任何写死的 slug / 绝对路径**，因此它可以被原样复制到目标仓库。
- **`tests/` 的存在与否就是"声明"本身**：没有声明文件，门禁无法区分「本项目没有测试」与「把 `tests/` 删了」—— 删除 `tests/` 等于显式声明不设项目测试套件，这是这条约定的已知边界（要堵这一点需要一个新的声明载体，属另一个切片）。
