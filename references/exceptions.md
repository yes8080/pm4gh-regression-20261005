# exceptions — 异常处理（纯规则）

> **何时读**：`scripts/preflight.sh` 有 `[FAIL]`、必需检查卡住、发现流程缺陷、或需求出现歧义时。
> 口径：本文件**只有规则**（触发 → 动作）。**禁止**写事故经过 / 时间线 / 复盘叙事；
> 平台层面的坑登记在 [traps.md](traps.md)，分步命令与判据在 [flow.md](flow.md)。

## 1. 触发 → 动作

| # | 触发 | 动作 |
|---|---|---|
| 1 | `scripts/preflight.sh` 输出含 `[FAIL]` | **停下**，按原文修完再动；**禁止**绕过，**禁止**先推进别的步骤 |
| 2 | 某必需检查**永久 pending**（同一 SHA 上始终不出结论） | 核对**该检查 job 的 `name:`** 与规则集里的必需 context 是否**逐字一致**（context = job 的 `name:`，**不是** workflow 文件名、**不是** workflow 的 `name:`）；并确认该工作流**无** `paths` / `branches` 过滤、监听 `pull_request` |
| 3 | `mergeStateStatus=BLOCKED` 但 `reviewDecision=APPROVED` | 判定该 SHA 的检查结论**已固化** → **推新提交**；只改 PR 正文 / 标签**不会**重跑检查 |
| 4 | **发现流程缺陷**（脚本 / 工作流 / 文档与实际不符） | **开 Bug Issue**：复现 / 期望 / 实际 / 影响 / 缓解；**禁止**在当前 PR 里顺手改掉 |
| 5 | **发现需求歧义** | **问** Issue 作者 / dispatcher，拿到答复再动；**禁止**自行扩大范围 |
| 6 | PR 正文 **>32KB** | `policy/linked-issue` 历史上会**误报**「缺少关闭关键字」（32KB 处 EPIPE，已修）→ 正文尽量精简；长正文以**最新 SHA** 的门禁结论为准 |
| 7 | 分支名不合规且需**终止**分支 | 走 `scripts/abort.sh <issue#>`（先 `--dry-run`）；**可见性边界**见 [traps.md](traps.md) |

## 2. 处置纪律

1. 门禁 FAIL → **报原文**；**禁止**改门禁 / 放松断言 / 删检查来"修好"。
2. 必需检查必须在**最新 SHA** 上全 `pass` 才进下一步；"先失败后通过"在该 SHA 上不可逆（见陷阱 1）。
3. 状态迁移只走 `scripts/status.sh`（**写迁移必须带 `--as author|reviewer|dispatcher`**，缺 → fail-closed 拒绝；只读模式不需要）；**禁止**手工 `gh issue edit` 增删 `status/*`（HTTP 层是两次并发 mutation）。
4. 无法用**真实输出**证明的事 → **禁止**断言；证据 = 命令 + 真实输出 / 检查名 / 运行链接。
5. 返修在**同一分支**；被打回后状态回 `in-progress`，**禁止**另开 PR。
6. 越界请求（改线上规则集 / 标签、增删脚本、改必需检查 job `name:`）→ **停下问** dispatcher。

## 3. 卡住时的最小取证（给 dispatcher 的固定三件套）

- **原始输出**：逐字贴 `[FAIL]` / `::error::` 那一行，不改写、不摘要。
- **定位**：命令 + `文件:行`（或检查名 + 运行链接）。
- **已排除项**：已核对的相邻条件（如 job `name:` 逐字一致、该 SHA 上的结论、是否最新 SHA）。
