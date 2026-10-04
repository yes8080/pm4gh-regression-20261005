# GOVERNANCE — 治理规则与决策记录

> 本文件回答"**谁有权做什么、什么算做完、例外怎么批**"。
> 操作步骤见 [PLAYBOOK.md](PLAYBOOK.md)；设计依据与官方引用见 [项目管理方案.md](项目管理方案.md)。

---

## 1. 角色与身份

| 角色 | 职责 | 当前承担者 | GitHub 载体 |
|---|---|---|---|
| PM / Lead | 里程碑立项、切片排序、DoR/DoD 把关、变更控制、返修升级决策 | `@yes8080` | Issue 模板、Milestone、Projects 视图 |
| Maintainer | 仓库设置、规则集、CODEOWNERS、Projects 字段、密钥与自动化 | `@yes8080` | 仓库 admin |
| Author / Dev | 实现、自测、交付 PR、响应评审 | `@yes8080` | Assignee + 分支 + PR |
| **Reviewer** | **独立**评审（非作者），给 Approve / Request changes | `@yes8080-reviewer-bot` | PR Review |
| **Acceptor / QA** | 按验收标准复现并验收 | `@yes8080-reviewer-bot` | PR 评论 `/accept`、`/reject` |
| Release | 打 tag、生成 release notes、里程碑治理 | `@yes8080` | `gh release` |

**为什么 Reviewer 必须是独立身份**：GitHub 平台**禁止自我批准**（`Review Can not approve your own pull request`）。
若用同一身份，要么门禁形同虚设，要么必须走 bypass —— 后者会让整套流程失去审计意义。
两身份由同一人操作是允许的（模拟团队），但**身份与审计记录必须分离**。

---

## 2. 权限矩阵

| 动作 | `@yes8080`（作者/admin） | `@yes8080-reviewer-bot`（评审/write） | 说明 |
|---|---|---|---|
| 建 Issue / 子 Issue / 依赖 | ✅ | ✅ | triage 即可 |
| 建分支、推送 | ✅ | ✅ | 规则集只保护 `main` |
| 打开 PR | ✅ | ✅ | |
| 批准 PR | ❌ **平台禁止自我批准** | ✅ | 授权清单 `.github/authorized-identities.txt` |
| 请求修改 / 验收记录 | ❌（对自己无意义） | ✅ | |
| 合并 PR | ✅ | ✅ | 需门禁全满足 |
| 直推 `main` | ❌ 被规则集拒绝 | ❌ | bypass 名单为空 |
| 删除/强推 `main` | ❌ | ❌ | `deletion` + `non_fast_forward` |
| 改规则集 | ✅（admin） | ❌ | 属高风险操作，见 §6 |
| 改仓库设置 | ✅ | ❌ | |
| 签发 Release | ✅ | ❌ | |

**授权清单**：`.github/authorized-identities.txt`。`ci/test` 强制校验其中**不得包含作者本人**（否则可自我验收）。

---

## 3. 决策记录（Decision Log）

| # | 决策 | 日期 | 依据 | 影响 |
|---|---|---|---|---|
| D1 | 仓库放**个人账号 `yes8080` + Pro + 私有仓库** | 2026-10-04 | 已付费；覆盖除 Projects 组织级特性外的一切 | 无 Issue Types / Issue Fields / 多评审人 / Merge Queue；用 `type/*` 标签 + Projects 字段承载 |
| D2 | 评审/验收用**独立第二身份** `@yes8080-reviewer-bot` | 2026-10-04 | 平台禁止自我批准 | 审批门禁得以真实生效 |
| D2b | 凭据形式：主身份用 gh 登录；评审身份用 **classic PAT**；`main.pat`（`repo`+`project`）仅在 Projects 场景需要 | 2026-10-04 | ①`GITHUB_TOKEN` 无 `projects` 权限（官方）②fine-grained PAT 无法用于 collaborator 仓库与用户级 Projects（官方，见方案 附录 C.3）③本机 `gh auth refresh` 在钥匙串上失败 | 凭据面最小化：评审身份独享一个 token |
| D3 | **单仓库 monorepo** | 2026-10-04 | 一套 `.github/`、一个 Projects、一套 Actions | 不使用跨仓库子 Issue（虽然官方允许同 owner 跨仓库） |
| D4 | M1 试点 = **本项目自举** | 2026-10-04 | 用真实流程建设自己 | 每个缺陷都成为真实需求 |
| D5 | `qa/acceptance` **降级为非必需审计检查** | 2026-10-04 | Bug #13 实测：必需检查不能"先失败后通过"，否则每个 PR 永久 BLOCKED | 验收的机器门禁回归原生审批规则；`/accept` 为审计证据 |
| D6 | CODEOWNERS 所有路径**必须含非作者 owner** | 2026-10-04 | Bug #13 第二死锁：仅作者 owner + `require_code_owner_review` = 永久不可合并 | 治理目录不再"仅主账号"，治理保护改由 CI 不变量 + 评审共同承担 |

---

## 4. 状态机（唯一状态源：Projects `Status`）

| 状态 | 进入条件 | 离开条件 |
|---|---|---|
| `Backlog` | Issue 已创建并有 Epic/Milestone 归属 | 满足 DoR → `Ready` |
| `Ready` | DoR 五项齐全、无未关闭阻塞（按 `state` 判定） | `scripts/start.sh` 建分支 → `In Progress` |
| `In Progress` | 分支已绑定 Issue、已指派 | PR 打开且必需检查通过 → `In Review` |
| `In Review` | PR 已开、检查全绿、正文含 `Closes #N` | 非作者批准 → `Acceptance`；打回 → `Rework` |
| `Acceptance` | 已批准 | `/accept` 记录 + 合并 → `Done`；`/reject` → `Rework` |
| `Rework` | 评审/验收打回且已给可核对清单 | 同分支继续提交 → `In Progress` |
| `Done` | PR 已合并、Issue 自动关闭、双端分支已删（`scripts/closeout.sh` 四项全过） | — |
| `Canceled` | PM 决策并记录原因 | — |

**注意**：父 Issue **不会**因子 Issue 全部关闭而自动关闭（官方无此联动）→ Epic 的关闭必须人工执行。
`Blocked` **不是状态**，由官方 `blockedBy` 关系表达；且该关系**不会因对方关闭而自动清除**，判断时只看 blocker 的 `state`。

---

## 5. DoR / DoD

### DoR（切片可开工，5 项）
1. **价值**：一句话说明交付什么价值。
2. **验收标准**：可判定条目；禁止"优化一下""完善体验"。
3. **边界**：明确不改什么。
4. **依赖**：`blockedBy` 已建且无未关闭阻塞；接口/契约已冻结。
5. **估算与归属**：`Size` 已填、执行者已指派、Milestone 已挂。

### DoD（切片可关闭，8 项）
1. 验收标准逐条有证据（测试名/命令/输出/截图）。
2. 5 项必需检查全绿。
3. 独立评审通过（非作者）。
4. 验收记录 `/accept` 存在。
5. 无未解决评审评论。
6. 文档/ADR 已更新（涉及接口、数据、运维变更时）。
7. 回滚路径明确可执行。
8. `scripts/closeout.sh` 四项全过。

---

## 6. 变更控制

| 变更类型 | 流程 |
|---|---|
| 普通切片 | 走标准流程（Issue → 分支 → PR → 评审 → 合并） |
| **流程/治理变更**（改 `docs/PLAYBOOK.md`、`docs/GOVERNANCE.md`、`.github/**`、`scripts/**`） | 同上，但**必须由非作者身份批准**（CODEOWNERS 已强制）；变更说明中必须写明动机与影响 |
| **规则集变更** | 属高风险：①先改仓库内 `.github/rulesets/main-protection.json` 并 PR 合入 ②再按 PLAYBOOK §9 分阶段应用 ③必须用真实 PR 验证；**禁止**在未验证情况下整份覆盖线上规则集 |
| **凭据轮换/撤销** | 立即在 `scripts/toolcheck.sh` 验证新凭据；旧凭据撤销后记录到本文件 §3 决策表 |
| **里程碑范围变更** | 新增切片必须挂 Milestone；未完成项迁移到下一 Milestone 并记录理由 |
| **检查改名** | 按 PLAYBOOK §9 的 4 步流程；改名会让所有 PR 永久 pending |

---

## 7. 返修与升级

1. 返修在**同一分支、同一 PR** 内继续（保证"一个 Issue = 一个分支 = 一个 PR"的干净历史）。
2. 推新提交会**驳回已有批准** → 必须重新评审（防止批准后被塞入未审代码）。
3. 挂 `src/rework` 标签，用于统计返修率。
4. **返修上限 2 次**；第 3 次打回触发升级，PM 必须二选一并在 Issue 中记录：
   - **切片重切**：原切片过大或边界不清 → 关闭原切片，拆成新的更小切片；
   - **需求澄清**：验收标准本身有歧义 → 冻结该切片，回到需求澄清。
5. 升级决策不可由作者单方面作出。

---

## 8. 度量定义（口径固定，避免各视图口径不一）

| 指标 | 定义 |
|---|---|
| 吞吐 | 每 Iteration 完成（`Done`）的切片数 |
| 周期时间 | `Ready` → `Done` 的中位时长 |
| 评审等待 | `In Review` 停留时长 |
| 一次通过率 | 未经历 `Rework` 的切片占比 |
| 返修率 | 挂过 `src/rework` 的切片 / 总切片 |
| 逃逸缺陷 | 已合并后新开 Bug Issue 的比例 |
| 阻塞时长 | `blockedBy` 存在期间的总时长 |

---

## 9. 例外与豁免

**唯一已批准的历史豁免**：切片 #2（仓库治理骨架）在规则集生效前直接提交到 `main`（bootstrap）。
依据：规则集尚未存在，无法自证门禁。已记录于 Issue #2。
**此后不再批准任何"直接提交到 main"的例外**；紧急情况请走 hotfix 分支 + 完整门禁，而不是绕开门禁。
