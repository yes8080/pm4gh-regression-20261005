# AGENTS.md — 任何 agent / 人的接手契约

> 本文件只写「必须做什么 / 禁止什么」。**怎么做、什么算做完**见 [docs/WORKFLOW.md](docs/WORKFLOW.md)。
> 人与 AI 使用同一套流程；AI 不享有「为了效率可以绕过」的豁免。

## 1. 开工前（缺一不可）

```bash
scripts/preflight.sh     # 任何一项失败 → 停下报告，不要"先干着看"
```

然后读 `docs/WORKFLOW.md`（它是唯一的流程权威）。

## 2. 一次只做一片

**一个切片 = 一个 Issue = 一个分支 = 一个 PR。** 同时只允许一个 `status/in-progress`。
工作顺序只有 W0..W8（见 `docs/WORKFLOW.md`），不得自创顺序。

## 3. 身份（平台强制，不是自觉）

三身份表、各自凭据与平台强制点见 **[docs/WORKFLOW.md §0](docs/WORKFLOW.md)**（唯一权威，本文件不复述）。
要点：作者走 `--as author`（`--as` 只接受 `author`），评审**不加** `--as`，只有 `@yes8080`（dispatcher）能
`gh pr merge --squash`；GitHub 禁止自我批准，规则集另有 `require_last_push_approval`（新推送驳回旧批准）与
`require_code_owner_review`。三者都不得越权。

## 4. 必须

1. 所有改动经 PR；PR 正文含 `Closes #<issue#>` 与六段模板（`.github/PULL_REQUEST_TEMPLATE.md`）
2. 留**可核对**的证据：命令、输出、检查名、运行链接。禁止"已测试通过"这类无证据断言
3. 状态只通过 `scripts/status.sh` 迁移（唯一源 = `status/*` 标签 + Issue 开关）
4. 提交身份用作者身份；提交信息用 `-F <文件>`（别把带反引号的多行文本内联进命令行）
5. 合并后必须跑 `scripts/closeout.sh <pr#>` 并五项全过
6. 关键节点在 Issue 留**简短**进度评论（分支已建 / 改动完成 / 遇到阻塞）

## 5. 禁止

| 禁止 | 原因 |
|---|---|
| 直推 / 强推 `main`，删 `main` | 规则集拒绝 |
| `gh pr merge --admin` 或任何绕过门禁的手段 | bypass 名单为空，绕过即失去审计意义 |
| 改 `.github/**`、`scripts/**`、`docs/WORKFLOW.md` 不走 PR | 这些是流程本身 |
| 改线上规则集或 `main-protection.json` | 写错会让**所有 PR 永久卡住**；属 dispatcher 权限，有疑虑就停下报告 |
| 改 5 个必需检查的 job `name:` | context 一旦改名/消失，所有 PR 永久 pending |
| 给必需检查工作流加 `paths`/`branches` 过滤 | 被跳过的检查永久 pending |
| 绕过 `status.sh` 直接改状态标签，或把状态写进本地文件 | 状态分裂 |
| 引入自己的流程（自建 TODO 文件、自己的状态机、自己的分支策略、共享库） | 流程只在仓库里 |

### 5.1 凭据口径（**唯一一处**；路径与 W0 开通见 [docs/WORKFLOW.md §0](docs/WORKFLOW.md)，别处只链接）

| 行为 | 判定 |
|---|---|
| 用**本身份**凭据执行**本身份**动作（作者用 `developer.pat` 推送/评论） | ✅ 允许（既有机制） |
| **读取其他身份**的凭据（作者读 `reviewer.pat` / `main.pat`） | ❌ 禁止 —— 越过身份，即可完成对自己 PR 的批准（`#94`） |
| **打印 / 提交**任何凭据（含本身份） | ❌ 禁止 —— 凭据泄露；`ci/test` 会扫描 |

**判据是机器判据不是自觉**：其他身份的凭据**必须在工作区之外** —— `scripts/review.sh` 与 `scripts/preflight.sh`
把凭据路径解析成绝对路径，落在仓库根之内 → `review.sh` 报错退出、`preflight.sh` 记 `[FAIL]` 隔离缺口。
**作者路径的脚本（`start.sh`/`deliver.sh`/`abort.sh`/`preflight.sh`）不读取评审凭据内容**；
评审凭据的认证与写权限由 W6 `review.sh` 用凭据自身判定。

**范围声明（这是工作区边界，不是身份隔离）**：判据提供的是**工作区边界**（凭据不得在仓库内，机器可查）与
**杜绝提交/泄露**（不可能被 `git add`、不会撞 `ci/test` 扫描）；它**不防御同一 OS 用户读取另一身份凭据** ——
作者本来就要读 `developer.pat`，同一用户能列 `$HOME/.config/pm4gh/` 就读得到 `reviewer.pat`，文件层面**不构成身份隔离**。
**真正的强制点是平台与契约**：① GitHub 拒绝自我批准 + 规则集 `require_code_owner_review`/`require_last_push_approval`；② 本节契约。**禁止**写成"作者取不到评审凭据"。

## 6. 异常处理

| 情况 | 正确反应 |
|---|---|
| `preflight.sh` 失败 | 停下，把失败项**原文**报告给 dispatcher |
| 必需检查永久 pending | 核对 job `name` 是否被改名、工作流是否被 `paths` 过滤（WORKFLOW.md §已知陷阱） |
| `mergeStateStatus=BLOCKED` 但 `reviewDecision=APPROVED` | 该 SHA 上留有**失败结论**的必需检查（不可逆）→ 报告，不要绕过 |
| 发现流程缺陷 | 开 Bug Issue（复现 / 期望 / 实际 / 影响版本 / 缓解），不要顺手改掉 |
| 发现需求歧义 | 停下请求澄清，不要自行扩大范围 |

## 7. 一轮工作的完成标准

见 **[docs/WORKFLOW.md §3 DoD](docs/WORKFLOW.md)**（唯一权威；本文件不再复述条目）。
