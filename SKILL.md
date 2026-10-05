---
name: pm4gh
description: "在当前仓库（由 `gh repo view` 推导，不写死 slug）把一个开发切片推完 GitHub 闭环：scripts/preflight.sh 预检 → 拆片 + 建 Issue（作者身份）→ 认领 Issue（DoR 五项）→ scripts/start.sh 开工建分支 → 提交 → scripts/deliver.sh 开 PR → 5 个必需检查 → scripts/review.sh 独立评审 → dispatcher squash 合并 → scripts/closeout.sh 收尾；并含 scripts/status.sh 状态迁移与 scripts/abort.sh 终止。当你要在本仓库接手某个 Issue、把改动交付成 PR、评审或合并某个 PR、推进或终止某个 Issue 的状态、排查本流程卡住或脚本报错，或要判断某项 GitHub 操作在本仓库是否被允许（能否直推 main、能否增删本仓库标签体系 `status/*`、`type/*` 等流程标签，*不是* release tag）时使用。在本仓库会话中，未点名的开工/交付/合并/收尾默认指本流程。不用于：把一个仓库**从零建成**这套治理（含在别的仓库首次安装本流程 —— 本 skill 用于**已就绪**仓库的日常推进）／GitHub Projects 与度量报表／跨模型评审留痕／能力开关／与本仓库无关的通用 Git/GitHub 操作。"
compatibility: "macOS（系统自带 bash 3.2）；需要 git、gh、jq（脚本另用 awk/sed/curl/diff）；GitHub 凭据必须在工作区之外，默认放 $HOME/.config/pm4gh/{developer,reviewer}.pat（可用 `DEVELOPER_PAT_FILE` / `REVIEWER_PAT_FILE` 覆盖）；改动线上规则集需要仓库 admin（属 dispatcher 权限）。"
metadata:
  version: "1.0.0"
  short-description: "多 agent + GitHub 开发闭环：认领→开工→交付→评审→合并→收尾"
  requires:
    bins: ["git", "gh", "jq"]
---

# pm4gh

本仓库只做一件事：**多 agent 用 GitHub 把一个开发切片跑完闭环**。状态只存在 GitHub（`status/*` 标签 + Issue 开关），没有本地状态文件。

## 输入

- **一个 Issue 号（或 PR 号）+ 你要做的事**。缺号先问 dispatcher，**禁止**推断，也**禁止**"先干着看"。
- 命令一律在**仓库根目录**执行；占位符 `<n>` / `<pr#>` 只填数字（不带 `#`，脚本会拒绝）。
- 身份：作者 = `--as author`（`developer.pat`）；评审 = 不传 `--as`（脚本自取 `reviewer.pat`）；合并 = 本机 `gh` 登录态。**不得读取其他身份的凭据**，**不得自批**。
- **用户显式指令优先于本 skill**；与本文件冲突时先停下确认。

## 切片拆分与分发（W0.5：一句目标 → 一组切片 Issue）

**输入**：一句目标（**不是**切片清单）。够不够格用 [references/flow.md](references/flow.md) 的 DoR 五项（W1）判。

- **谁拆**：接手该目标的 agent（作者身份）。人 / dispatcher 只在**目标本身有歧义**时介入（[references/exceptions.md](references/exceptions.md) 第 5 条），**不**代为拆片。
- **粒度**：一条切片 = **恰好一个可合并的改动** = 一个 Issue = 一个分支 = 一个 PR = 一次可独立回滚（1~3 个工作日）。三条判据同时成立才算够格：① 一个 PR 的六段能写清；② 能独立回滚，不依赖其他**未合并**切片；③ 验收标准逐条可判定。
- **拆 / 并的判据**：两条切片要改**同一文件的同一区域**、或**必须一起合并**才能验收 → 合成一条；一条切片里出现**两个互不依赖**的可合并改动 → 拆成两条。同文件但区域不相交 → 保持两条，用 **blocked by** 串行（`gh issue create --blocked-by <n>`），不合并、不并发。
- **谁建 Issue**：**作者身份** —— `GH_TOKEN="$(cat "$HOME/.config/pm4gh/developer.pat")" gh issue create …`；非交互必须 `--body-file` + 显式 `--label`（[references/traps.md](references/traps.md) 陷阱 16）。**禁止**用本机 `gh` 登录态（dispatcher）建切片 Issue —— 审计归属 = 做事的人。
- **每条 Issue 的最低内容**：DoR 五项（① 价值一句话 ② 可判定的验收标准 ③ 明确不改什么 ④ 依赖与契约 ⑤ 规模与执行者，逐字见 [.github/ISSUE_TEMPLATE/slice.yml](.github/ISSUE_TEMPLATE/slice.yml)）；标签 `type/*` + `role/dev`（`area/*` / `prio/*` 按需，它们是人类元数据）；依赖用 `--blocked-by` 建立。
- **状态起点**：建单后停在 **`backlog`**（OPEN 且无 `status/*`）。`ready` **不是**建单的必经步骤 —— `backlog → in-progress` 是合法边，`scripts/start.sh` 从 `backlog` 也能直接开工（[references/status-machine.md](references/status-machine.md)）。
- **产物**：N 条 `backlog` Issue（**不是** PR、不是代码）。**禁止**只产出一条"什么都做"的大切片（= 没有拆分），也**禁止**产出没有验收标准的切片。

## 工作流程

1. **预检**（每次接手第一步）：`scripts/preflight.sh` → 全 `[ OK ]` 且退出码 `0`；任一 `[FAIL]` → 贴原文报 dispatcher，**禁止**继续。
2. **开工**：DoR 五项齐备才 `scripts/status.sh <n> ready --as author`；再 `scripts/start.sh <n> --as author`（线上故障加 `--type hotfix`）。
3. **交付**：提交用 `-F <文件>` + 作者 git 身份；`scripts/deliver.sh <n> --prepare --as author` 生成六段 → 填写 → `scripts/deliver.sh <n> --as author`。
4. **检查**：`gh pr checks <pr#> --required` —— 5 个必需检查在**最新 SHA** 上全 `pass` 才进下一步。
5. **评审**：`scripts/review.sh <pr#> approve --body-file <文件>`（评审身份；打回时把 `approve` 换成 `request-changes`）；打回 → 状态 `in-progress`，**同一分支**返修。
6. **合并收尾**：只有 dispatcher 能 `gh pr merge <pr#> --squash --delete-branch`；随后 `scripts/closeout.sh <pr#>` 五项全过。
7. **终止**：只在"不做"时 `scripts/abort.sh <issue#>`（先 `--dry-run`）；删分支前必须能证明内容不会丢。

## 输出

- **一个 PR**：正文含 `Closes #N` + `## 1.`..`## 6.` 六段；Issue 状态随 W2..W7 迁移，关键节点在 Issue 留**简短**进度评论，终止时留可恢复锚点。
- **证据**：命令 + 真实输出 / 检查名 / 运行链接。**禁止**"已测试通过"这类无证据断言。

## 完成标准

[references/dod.md](references/dod.md) 六项全过（验收标准逐条有证据；必需检查最新 SHA 全绿 + 非作者 code owner 批准；未越界；`closeout.sh` 五项全过）。

**必要约束（不回退）**：15 边 / 6 状态｜状态迁移 = REST `PUT …/labels` **单请求**｜5 个必需检查 job `name:` 一字不改｜凭据必须在**工作区之外**｜一个切片 = 一个 Issue = 一个分支 = 一个 PR｜项目测试套件约定 = `tests/run.sh`（`exit 0` = 通过），由 `ci/test` 运行、`preflight.sh` 断言接线；无 `tests/` = 未声明（两处都明确打印，不静默跳过）｜每个断言区分 **通过／失败／未执行**（未执行必须打印且不计入通过，见 [references/exceptions.md](references/exceptions.md) §4）｜文档里的 `scripts/*.sh` 命令形态由 `ci/test` 与脚本**真实参数解析**逐条对齐（脚本提供 `--parse-only` 零副作用解析路径，**不得删除**）。

## 支持资料

按当前阶段**只读对应的一个文件**，不要预先全读。

| 何时读 | 文件 |
|---|---|
| 开工 / 交付 / 返修的每步命令与判据 | [references/flow.md](references/flow.md) |
| 任何一次状态迁移之前 | [references/status-machine.md](references/status-machine.md)（15 边 / 6 状态的唯一表权威） |
| 首次开通身份凭据，或身份 / 凭据报错 | [references/identity.md](references/identity.md) |
| 现象对得上某条坑（检查永久 pending、推送变了身份…） | [references/traps.md](references/traps.md) |
| 预检有 `[FAIL]`、必需检查永久 pending、需要终止分支 | [references/exceptions.md](references/exceptions.md)（异常处理：触发 → 动作；**发现流程缺陷开 Bug Issue**） |
| 写 PR 第 5 节 DoD 自查，或合并前核验 | [references/dod.md](references/dod.md) |
| 填 PR 六段 / 建 Issue 表单 | [assets/README.md](assets/README.md) → `.github/` 里的平台强制模板 |
| 确定性、多步、有副作用的 GitHub 操作 | [scripts/](scripts/)（7 个脚本，自包含；**不得新增脚本**） |
| 安装到客户端 | 在**本仓库根目录**执行：主推 `mkdir -p ~/.agents/skills && ln -s "$(git rev-parse --show-toplevel)" ~/.agents/skills/pm4gh`；兼容 `mkdir -p ~/.claude/skills && ln -s "$(git rev-parse --show-toplevel)" ~/.claude/skills/pm4gh` |
| 把本 skill 装到**另一个仓库** | [references/portability.md](references/portability.md)（采用者**替换点清单**：每条给 `file:line` + 换成什么 + 是否有机器判据） |
| 在**新仓库**落地（或从零建）这套治理 | [references/bootstrap-checklist.md](references/bootstrap-checklist.md)（新项目启动清单：平台陷阱 20 条 ＋ preflight 会断言的 10 条治理假设 ＋ 替换点 11 条；**逐条抄一遍**，覆盖度由 `ci/test` 断言） |

**明确不做**：把一个仓库**从零建成**这套治理（在别的仓库首次安装 = 按 [references/portability.md](references/portability.md) 逐条替换，不属于本 skill 的执行范围）、Projects、度量报表、跨模型评审留痕、能力开关、共享库；**不引入第二套规范文档** —— `SKILL.md` + `references/**` + `.github/**` + `scripts/**` 就是全部权威。

**里程碑（Milestones）同样不做 —— 这是决定，不是缺口**：① 它不是状态源，本 skill **零消费**（`grep -rn -i milestone SKILL.md references/ scripts/ .github/` = 0 命中；`preflight.sh` 的 10 组与 `ci/test` 都没有里程碑不变量）；② 交付单元是「一个切片 = 一个 Issue = 一个分支 = 一个 PR」，里程碑只在「多切片归一个目标」时有意义 —— 那是组合 / 排期，与上面已排除的 Projects、度量报表同类；③ 原生行为不满足「全关即完成」（实测 2/2 关闭后 `state` 仍为 `open`，必须再发一次 `PUT/PATCH …/milestones/<n>` 手动关闭）→ 引入它 = 引入一条**无判据、需人工收尾**的路径；④ `gh` 没有 `milestone` 子命令（`gh milestone --help` → `unknown command "milestone"`），CRUD 只能走 REST，而本 skill 只有 7 个**不新增**的自包含脚本，没有自然挂载点。多切片归组改用**父子 Issue**（`gh issue create --parent <n>` / `gh issue edit <n> --add-sub-issue <n>`，已实测可用）与 [references/status-machine.md](references/status-machine.md) 的非切片 `backlog → done` 路径承载。采用者自用里程碑**不受阻断** —— 本 skill 只是不规定、不消费它。
