# portability — 采用者替换点清单（把本 skill 装到**另一个仓库**）

> **何时读**：要把本流程用于**另一个仓库**时。本仓库日常推进**不需要**读本文件。
> 口径：本 skill 面向**已就绪**仓库的日常推进，「从零建成一套治理」不在它的执行范围内 ——
> 但「建成」需要改的东西就是下面这张清单，逐条替换完即在目标仓库就绪。

## 0. 安装位置与文件归属

独立 **skill 源仓库**的根目录可以就是 skill 目录。本仓库采用该布局，便于发布和维护。
**业务项目**推荐把 skill 固定版本放在 `.agents/skills/pm4gh/`，避免把源仓库整体 clone 成业务项目或把其文件散铺在业务根目录。

```text
业务项目/
├── .agents/skills/pm4gh/
│   ├── SKILL.md
│   ├── references/
│   ├── scripts/
│   └── assets/
├── .github/                 GitHub 平台文件：工作流、规则集、表单、PR 模板、CODEOWNERS
├── tests/run.sh             业务项目自己的测试入口（项目声明测试时）
└── 业务代码
```

- **发现 skill**：项目内 `.agents/skills/pm4gh/` 供团队共享并随仓库版本化；用户级 `~/.agents/skills/pm4gh/` 可用于跨项目个人安装。Codex 支持指向 skill 文件夹的符号链接。不要把同名的项目级和用户级副本视为自动合并。
- **安装到客户端**：独立源仓库可执行 `mkdir -p ~/.agents/skills`，再执行 `ln -s "$(git rev-parse --show-toplevel)" ~/.agents/skills/pm4gh`。若目标已经存在，先确认其来源，不覆盖。客户端其他发现目录按其自身文档配置。
- **安装不等于治理就绪**：用户级链接只让 AI 看见 skill；它不会复制平台文件或配置目标仓库的规则集、标签、协作者和身份。当前流程要求目标仓库拥有自己的 GitHub 治理。
- **业务项目安装**：从同一个已审阅的上游 commit 复制 `SKILL.md`、`references/`、七个 `scripts/` 和 `assets/` 到项目 skill 目录；合并所需 `.github/` 配置，不能覆盖项目既有工作流、表单或 CODEOWNERS；再完成 §1 的替换和 bootstrap 验证。不复制上游 `.git`、测试日志或凭据。
- **执行目录**：始终站在目标仓库根，执行 `.agents/skills/pm4gh/scripts/preflight.sh` 等实际路径。脚本从自身位置读取 skill 资料，从目标仓库读取 `.github/`、业务测试和 GitHub 实体。不能进入用户级 skill 的源仓库来替业务项目做操作。
- **两个布局都支持**：根目录布局的命令为 `scripts/preflight.sh`；项目布局使用完整前缀。CI 只允许一个入口，在 CI runner 内建立临时治理视图供已有 skill 契约测试读取 `.github/`；项目测试和凭据扫描仍从业务仓库根运行。临时视图不提交到项目，也不是生产安装文件。
- **升级与回滚**：通过一个 PR 同步同一上游 commit 的整个 skill 和匹配工作流；保留项目账号、链接等替换值。不可仅移动 SKILL.md、只升级一部分脚本或把 CI 继续指向旧路径。

OpenAI 参考：[Build skills](https://learn.chatgpt.com/docs/build-skills)；[Rethinking skills and prompts](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)。前者说明发现目录和渐进加载；后者建议缩短描述、按需路由。这里的 GitHub 治理布局是本项目的设计选择，不是 OpenAI 对所有 skill 的要求。

**锚点记法（#160 起，替代 `file:line`）**：每条替换点的「在哪」写成两段 —— 先给路径（如 `scripts/deliver.sh`），
紧跟一组锚点标记：全角左括号 + `锚点：` + 反引号括起的字面文本 + 全角右括号；一条可给多个锚点，用 `；` 分隔。
锚点是在**该文件里逐字存在**的片段（标签 / 键名 / 结构标记，**不是**新发明的标记）。**定位靠锚点、不靠行号**：行号会随上游增删行**静默漂移**（#154 实测：`SKILL.md` 的安装路径行从 58 漂到 70、`references/flow.md` 的作者身份样例行从 51 漂到 52），
锚点不会。判据（常驻 `ci/test`）：① 本文件与 `bootstrap-checklist.md` 零 `path:line` 形态；
② 每个锚点在目标文件里**逐字存在**（缺失 → `FAIL` 并指出条目 + 文件）；③ 其余文档里含 `path:line` 的行**必须**同行带锚点。
锚点优先选**不会随替换一起消失**的文本（如 `DEVELOPER_PAT_FILE=` 这类键名），避免"替换完锚点也没了"。

## 1. 替换点（每条：在哪 `路径` + 锚点 → 换成什么 → 是否有机器判据）

| # | 替换点 | 在哪（`路径` + 锚点） | 换成什么 | 机器判据 |
|---|---|---|---|---|
| 1 | **仓库 slug** | `.github/ISSUE_TEMPLATE/config.yml`（锚点：`contact_links:`；`url:`）—— 即三条 `https://github.com/<owner>/<repo>/blob/main/…` | 目标仓库的 `<owner>/<repo>` 与 skill 实际路径（项目布局为 `.agents/skills/pm4gh/`） | ✅ `preflight.sh` 第 8 段 **P6 链接断言**：`.github/` 内 `github.com/<owner>/<repo>` ≠ 当前 slug（`gh repo view`）→ `[FAIL]` 并逐条列出。slug 本身不写死 |
| 2 | **三身份用户名** | 作者 `@<author-bot>`：`references/identity.md`（锚点：`拆片 + 建 Issue`）、`.github/CODEOWNERS`（锚点：`三个身份：作者`）、`.github/ISSUE_TEMPLATE/slice.yml`（锚点：`执行者:`）、`references/flow.md`（锚点：`git -c user.name=`）、`scripts/start.sh`（锚点：`git -c user.name=`）；评审 `@<reviewer-bot>`：`references/identity.md`（锚点：`**不得合并**`）、`.github/CODEOWNERS`（锚点：`所以下面所有规则都写成`）、`references/flow.md`（锚点：`**必须**：由 `）；合并 `@<dispatcher>`：`references/identity.md`（锚点：`gh pr merge --squash`）、`.github/CODEOWNERS`（锚点：`三个身份：作者`）、`.github/PULL_REQUEST_TEMPLATE.md`（锚点：`合并：gh pr merge`）、`references/flow.md`（锚点：`--squash --delete-branch`；`用本机登录态合并`） | 目标仓库的三个真实账号（作者 ≠ 评审 ≠ 合并） | ✅ 部分 —— 第 8 段从 `references/identity.md`（锚点：`**不得合并**`）解析**评审身份**并断言「是协作者 + 有 push + 是 `*` 规则 owner」；第 5/8 段断言作者（凭据登录名）与合并（`gh` 登录态）互不相同且是协作者。模板里的展示名无判据 |
| 3 | **作者 git 身份（提交署名）** | `scripts/start.sh`（锚点：`用作者身份提交`；`git -c user.name=`）、`references/flow.md`（锚点：`git -c user.name=`）—— 仓库内唯一的署名提示 + 命令样例 | 作者账号的 `user.name` / `user.email`（`<id>+<login>@users.noreply.github.com`） | ❌ 无 —— 提交署名不参与任何必需检查，人工确认 |
| 4 | **凭据路径 / 单写者锁路径** | 凭据默认 `$HOME/.config/pm4gh/{developer,reviewer}.pat`；单写者锁默认 `$HOME/.config/pm4gh/locks`（**工作区之外**；模型见 `references/orchestration.md` §7）。凭据：`SKILL.md`（锚点：`$HOME/.config/pm4gh/{developer,reviewer}.pat`）、`references/identity.md`（锚点：`$HOME/.config/pm4gh/developer.pat`；`$HOME/.config/pm4gh/reviewer.pat`；`DEVELOPER_PAT_FILE`；`printf '%s\n' '<作者 PAT>'`）、`scripts/preflight.sh`（锚点：`DEVELOPER_PAT_FILE=`；`REVIEWER_PAT_FILE=`；`LOCK_DIR=`）、`scripts/start.sh`（锚点：`DEVELOPER_PAT_FILE=`）、`scripts/deliver.sh`（锚点：`DEVELOPER_PAT_FILE=`）、`scripts/review.sh`（锚点：`REVIEWER_PAT_FILE=`）、`scripts/abort.sh`（锚点：`DEVELOPER_PAT_FILE=`） | **优先不改脚本**：用 `DEVELOPER_PAT_FILE` / `REVIEWER_PAT_FILE` 指向目标路径（默认值只是默认）；锁目录用 `PM4GH_LOCK_DIR`（不可写时脚本**回退**到 `/tmp/pm4gh-locks-<uid>` 并打印原因，**不回退**显式指定的值） | ✅ 第 5 段：凭据存在 / 权限 `600` / 未被 git 跟踪 / **在工作区之外**（工作区内出现任何 `*.pat` → `[FAIL]`）；`review.sh` 对工作区内路径**拒绝执行**。第 3 段：锁目录可用（两个候选都不可写 → `[FAIL]`），锁只在**本 clone**的锁文件上判定 |
| 5 | **CODEOWNERS owner 列表** | `.github/CODEOWNERS`（锚点：`*  `；`三个身份：作者`；`所以下面所有规则都写成`）—— 规则行 `*  @…` 与注释里的三身份 | 目标仓库的**非作者** owners（评审 + 合并共同拥有；作者不得是任何路径的唯一 owner） | ✅ 第 8 段：每个 owner 是协作者且有 push；评审身份是 `*` 的 owner；合并身份是协作者（`require_code_owner_review` 下防永久锁死） |
| 6 | **`ISSUE_TEMPLATE/config.yml` 链接本身** | `.github/ISSUE_TEMPLATE/config.yml`（锚点：`contact_links:`；`about: `）—— `name` / `url` / `about` 三条 | 指向目标仓库 skill 目录内的 `SKILL.md` / `flow.md` / `status-machine.md`；目标仓库不用这些文档时改成中性名称或删掉该条 contact link | ✅ 同 #1（P6）；`about` 文案无判据 |
| 7 | **`SKILL.md` 安装路径** | `SKILL.md`（锚点：`安装到客户端`；`ln -s "$(git rev-parse --show-toplevel)"`）、`references/identity.md`（锚点：`mkdir -p ~/.agents/skills`；`$(git rev-parse --show-toplevel)`） | 已是**相对当前仓库**写法（`ln -s "$(git rev-parse --show-toplevel)"`）→ 通常**无需替换**；只在客户端扫别的目录时改 `~/.agents/skills` / `~/.claude/skills` | ❌ 无（文档命令）。人工核对：`grep -rn '/Users/' $(git ls-files)` 应为零命中 |
| 8 | **测试床 / 绝对路径引用** | `.github/workflows/required-checks.yml`（锚点：`# ② stub gh：`；`STUB_AUTHOR_TOKEN`）—— stub `gh repo view` 返回源 slug / stub 作者登录名所在块；仓库内**不得**再有 `/Users/<you>/…` 绝对路径 | stub 值换成目标仓库 slug / 作者登录名（仅测试夹具，不改也过 CI）；绝对路径换成相对或占位 | ❌ 无（stub 值不参与断言）。人工核对：`grep -rn '/Users/' $(git ls-files)`、`grep -rn 'github.com/' .github/` |
| 9 | **流程标签体系 + Issue 表单**（目标仓库为空时需先建） | `scripts/preflight.sh`（锚点：`MACHINE_LABELS="status/ready`；`DOR_ASSERT`）+ Issue 表单的 `labels:` 与 DoR 五项 label（`.github/ISSUE_TEMPLATE/slice.yml`（锚点：`labels:`）、`.github/ISSUE_TEMPLATE/bug.yml`（锚点：`labels:`）） | 在平台上 `gh label create` 建齐同名标签（或改成目标仓库自己的标签名并同步脚本/模板）。**表单必须存在且完整**：`bug.yml` / `slice.yml` 随 `.github/**` 一起复制；加自己的表单也可以，但**每张表单**都得含 DoR 五项 label（与 `slice.yml` 逐字一致），且**至少一张**含完整缺陷证据字段集（复现步骤 / 期望 vs 实际 / 影响版本 / 证据 / 回滚·临时缓解） | ✅ 第 9 段：① 机器消费 + 表单预置的标签必须都存在（判据 `LABEL_ASSERT`，带反向样本）；② **表单完整性**（判据 `DOR_ASSERT`，与 `ci/test` 逐字一致 + **动态枚举**全部表单）：缺哪个 DoR label 会当场列出「文件 + label」，目录缺失 → `[FAIL]`（理由见 §2"已知取舍"） |
| 10 | **门禁接线**（规则集 / 必需检查名） | `.github/rulesets/main-protection.json`（锚点：`"target"`；`"enforcement"`）、5 个必需检查的 job `name:`（`.github/workflows/required-checks.yml`：锚点：`name: ci/lint`；`name: ci/test`；`name: policy/linked-issue`；`name: policy/branch-name`；`name: policy/template`） | 在目标仓库建同名规则集；`name:` **一字不改**（改名 = 所有 PR 永久 pending） | ✅ 第 7 段（job `name:` 与 5 个必需 context 逐字一致）+ 第 8 段（线上规则集整份 diff，全量键） |
| 11 | **项目测试套件入口**（采用者若已有测试，放这里即**自动接入**门禁） | `tests/run.sh`（目标仓库里通常**还不存在**；本仓库本身也没有 = 未声明测试套件）—— 契约文本见 `references/flow.md`（锚点：`tests/run.sh`）与 `scripts/preflight.sh`（锚点：`tests/run.sh`） | 把已有的测试入口放到 `tests/run.sh`（`exit 0` = 通过，非零 = 失败）并 `chmod +x tests/run.sh`。**没有测试就不要建 `tests/`** —— 无 `tests/` 即「未声明」，两处都打印说明行 | ✅ `ci/test`「项目自身测试套件」step（有则**运行**它；缺入口 / 无 `x` 位 → FAIL）+ `preflight.sh` 第 3 段（有 `tests/` → 入口必须存在且可执行）。**无需**改规则集 / 5 个 job `name:` |

## 2. 已知取舍

- **P6 判据不猜意图**：`.github/` 里指向**第三方**仓库的 `github.com/…` 链接同样会被判不一致。确需引用第三方时写成不含 `github.com/` 的 `owner/repo` 文本，或报告 dispatcher 说明。
- **`references/identity.md` 的评审身份行（锚点：`**不得合并**`）是评审身份的机器可读载体**：第 8 段从那张表解析评审用户名，改表 ≠ 改得对 —— 必须同时是目标仓库的协作者且有 push，否则 `preflight.sh` 报 `[FAIL]`。
- **本文件自身不含任何写死的 slug / 身份名 / 绝对路径**，因此它可以被原样复制到目标仓库。（锚点只引结构标记与键名，不引源仓库的账号。）
- **锚点不引「要被替换掉的值」**：例如三身份用的是 `拆片 + 建 Issue` / `执行者:` / `git -c user.name=` 这类角色标签，而不是 `@<bot>` 本身 —— 替换完锚点仍在，判据不会变成"采用者的假 FAIL"。
- **`.github/ISSUE_TEMPLATE/` 目录缺失 = `[FAIL]`，不是"未声明就跳过"**（`DOR_ASSERT`）：表单是「DoR 五项齐备」这条契约在**建单**这一步的唯一固定载体，而 `config.yml` 已把空白 Issue 关掉 —— 目录没了，采用者建单时**无表单可走**，契约当场落空。宽容处理（目录不存在 → 跳过）等于「删掉目录即绕过门禁」（假绿），故取 fail-closed。代价：采用者必须让该目录随 `.github/**` 一起落地，并保证每张表单都填齐 DoR 五项 label；**加自己的表单不会被拦，但不含 DoR 五项的加不进来**（这正是要防的"新增表单绕过"）。
- **`tests/` 的存在与否就是"声明"本身**：没有声明文件，门禁无法区分「本项目没有测试」与「把 `tests/` 删了」—— 删除 `tests/` 等于显式声明不设项目测试套件，这是这条约定的已知边界（要堵这一点需要一个新的声明载体，属另一个切片）。
