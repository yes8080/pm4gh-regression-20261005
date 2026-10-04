# TOOLING — 开发工具接入与切换协议

> **本项目的核心目标之一：切换开发工具，项目仍能正常推进。**
> 实现方式只有一条路：**所有状态在 GitHub，流程在仓库里，本地不留私有状态。**
> 任何新工具（CLI / IDE / AI Agent / 换一台机器）都应能在 10 分钟内接手。

---

## 1. 最低能力要求

| 能力 | 是否必需 | 说明 |
|---|---|---|
| `git` | ✅ 必需 | 克隆、分支、提交、推送 |
| `gh` CLI | ✅ 必需 | Issue/PR/评审/规则集/Projects 的全部操作入口 |
| `jq` | ⚠️ 脚本需要 | `scripts/*` 与部分检查依赖它 |
| 浏览器 | ⚠️ 偶发 | 接受 collaborator 邀请、签发 token、规则集应急回退 |
| 具体编辑器 / IDE / Agent | ❌ 不要求 | 任何工具都可以，只要能跑上面两条 |

**明确不依赖**：任何商业项目管理工具、任何本地看板、任何"只存在于某个工具里"的状态。

---

## 2. 接入检查清单（新工具/新机器 10 分钟）

```bash
# ① 克隆
git clone https://github.com/yes8080/pm4gh.git && cd pm4gh

# ② 环境与凭据自检（8 项）
scripts/toolcheck.sh

# ③ 读三份文档（顺序不要变）
#    docs/PLAYBOOK.md   → 怎么做每一步
#    docs/GOVERNANCE.md → 什么算做完、谁能做什么
#    AGENTS.md          → 如果你/我是 AI 工具

# ④ 看当前事务
gh issue list -R yes8080/pm4gh --state open --limit 20 --json number,title,labels
bash scripts/audit.sh

# ⑤ 领一个可开工的切片并跑通一轮
gh issue list -R yes8080/pm4gh --label role/dev --state open
scripts/start.sh <issue#>
```

**判断接入成功**：你能不借助任何外部口头说明，独立完成 `start.sh → 实现 → deliver.sh → review.sh → merge → closeout.sh`。

---

## 3. 状态在哪（供任何工具读取）

| 状态 | 唯一来源 | 读取命令 |
|---|---|---|
| Issue 阶段 | Projects `Status` 字段（**唯一状态源**） | `gh project item-list <n> --owner yes8080 --format json` |
| 阻塞关系 | Issue 的 `blockedBy`（**注意：只看 blocker 的 `state`**） | `gh issue view <n> --json blockedBy` |
| 分支 ↔ Issue 绑定 | `gh issue develop --list` | `gh issue develop --list <issue#>` |
| PR 门禁 | `reviewDecision` + `mergeStateStatus` + checks | `gh pr view <pr#> --json reviewDecision,mergeStateStatus` |
| 规则集 | 仓库内 `.github/rulesets/main-protection.json`（线上应一致） | `scripts/toolcheck.sh` 会比对 |
| 凭据状态 | `.secrets/`（**不读取内容，只检查存在性与可用性**） | `scripts/toolcheck.sh` |

---

## 4. 交接块（换工具/换人/换 Agent 的标准格式）

在对应 Issue 上追加一条评论，结构固定：

```markdown
<!-- HANDOFF:v1 -->
- 当前状态：In Progress（Projects Status）
- 分支：slice/12-xxx（已推送：是/否）
- 已完成：<可核对条目>
- 未完成 / 下一步：<可核对条目>
- 阻塞：无 / blockedBy #NNN（其中哪些仍 OPEN）
- 本地未推送提交：无
- 需要接手者先跑：scripts/toolcheck.sh
```

**接手的工具应当**：先 `toolcheck.sh`，再读交接块，再继续 —— 不需要任何口头/聊天上下文。

---

## 5. 工具切换演练（本项目的终验）

**演练定义**：用一个**此前未参与本项目**的工具/身份（或换一台机器），**只允许阅读仓库文档 + 使用 `git`/`gh`**，完成：

> 领切片 → 建分支 → 提交 → 提 PR → 全绿检查 → 独立评审 → 验收 → 合并 → 双端删分支 → 收尾核验

**通过标准（五项缺一不可）**
1. 全程无需任何口头/聊天补充说明；
2. 无需手工修补 Projects 状态（自动流转生效）；
3. 无孤儿分支（本地与远程均干净，`scripts/closeout.sh` 四项全过）；
4. Issue ↔ 分支 ↔ PR ↔ 合并记录四者链接完整；
5. 演练前后度量口径不变（同一套定义，见 GOVERNANCE §8）。

**演练报告**须写入 `docs/`，含：使用工具、耗时、卡点、失败点、改进项。

---

## 6. 已知工具差异（避免"换个工具就变流程"）

| 工具类型 | 常见差异 | 本项目要求 |
|---|---|---|
| 图形化 Git 客户端 | 可能默认用 merge 而非 squash | 合并必须 squash（规则集也强制） |
| 编辑器/IDE 的 GitHub 集成 | 可能提供"直接提交到 main" | 会被规则集拒绝；请走 PR |
| AI Agent | 可能倾向"顺手多改几处" | 禁止越界修改；一次一个切片 |
| 其他 CI 工具 | 可能生成同名检查但来源不同 | 必需检查由本仓库工作流产生；不要用外部 App 冒充 |
| 新版 `gh` | 子命令与旗标可能变化 | 以 `docs/PLAYBOOK.md` §4 记录的实际行为为准；发现差异先修文档 |

---

## 7. 不变量（换工具也不允许变的七件事）

1. 状态只在 Projects `Status`；
2. 一个切片 = 一个 Issue = 一个分支 = 一个 PR；
3. `main` 只能经 PR 进入，且只允许 squash；
4. 必需检查名不得随意更改；
5. 评审身份必须与作者不同；
6. 凭据永不入库；
7. 发现的缺陷走 Bug Issue，不"顺手改掉"。
