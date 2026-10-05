# assets — 平台强制模板的**源**与用法

> **何时用**：填 PR 正文六段时（`scripts/deliver.sh --prepare` 生成的骨架与它同构）；用 Issue 表单建 Issue 时。

## 为什么这里没有模板副本

本仓库模板的**源**被 GitHub 强制放在 `.github/` 的固定路径，平台只认那些位置 —— 搬走等于让表单 / 模板失效。所以 `assets/` 不复制副本（复制 = 两份会漂移的真相），只做**指路**。

**二者关系**：`.github/**` = 平台强制位置，唯一真相；`assets/` = 说明与用法。

| 模板源（唯一真相） | 平台作用 | 谁在消费 | 何时用 |
|---|---|---|---|
| [`.github/PULL_REQUEST_TEMPLATE.md`](../../../../.github/PULL_REQUEST_TEMPLATE.md) | 新建 PR 时自动填充 | `policy/template` 断言 `## 1.`..`## 6.`；`deliver.sh --prepare` 生成同构骨架 | W4 交付前填六段 |
| [`.github/ISSUE_TEMPLATE/slice.yml`](../../../../.github/ISSUE_TEMPLATE/slice.yml) | 切片 Issue 表单（DoR 五项） | W1 领片判据 | 建切片 Issue |
| [`.github/ISSUE_TEMPLATE/bug.yml`](../../../../.github/ISSUE_TEMPLATE/bug.yml) | Bug / 线上故障表单（轨道、级别、复现、证据） | `start.sh` 的 `type/*` 推导 | 建 Bug / 热修 Issue |
| [`.github/ISSUE_TEMPLATE/config.yml`](../../../../.github/ISSUE_TEMPLATE/config.yml) | 关闭空白 Issue + 联系入口 | 平台 | 建任何 Issue 前 |
| [`.github/CODEOWNERS`](../../../../.github/CODEOWNERS) | 路径 owner | 规则集 `require_code_owner_review` | 改任何路径前确认有**非作者** owner（[traps.md](../references/traps.md) 陷阱 4） |

## 六段结构（`policy/template` 逐段断言）

`## 1. 变更摘要` ｜ `## 2. 影响面` ｜ `## 3. 回滚方式` ｜ `## 4. 验收证据` ｜ `## 5. DoD 自查` ｜ `## 6. 风险与破坏性变更`

- 第一行 `Closes #N` 由 `policy/linked-issue` 强制（**PR 标题里的关键字无效**）。
- 每段非空白字符 ≥ 20（`deliver.sh` 的判据）。

## 与脚本的分工

`scripts/deliver.sh --prepare` 只为**可写正文**生成骨架（平台模板在 API 建 PR 时不生效）；Issue 表单由**平台 UI** 消费。二者都源自 `.github/`，改模板只改那里。
