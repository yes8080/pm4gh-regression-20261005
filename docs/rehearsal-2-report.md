# 第二次工具切换演练报告（方案 §10.4 要求的终验）

> 结论先行：**主流程通过（5 项标准中 4 项通过）**；第 5 项"度量口径不变"**未通过**，原因是被验出**口径二义**（同一指标两份冲突定义）。
> 这是演练最有价值的产出：它审出的是"文档承诺了但系统没做到"的地方。所有发现均已修复或开单。

## 1. 演练设定

| 项 | 内容 |
|---|---|
| 目的 | 证明"**换开发工具，项目仍能正常推进**" |
| 执行者 | 一个**完全没有本项目会话上下文**的独立 agent（盲执行） |
| 提供的信息 | **仅**：仓库地址 + 本地路径 + Issue 编号（#27）+ "按项目自己的文档执行"。**未提供任何步骤说明** |
| 被验切片 | #27 `scripts/report.sh`：用搜索 API 替代 Projects Insights 的度量出口（Size 3，含只读约束与兼容性铁律） |
| 耗时 | 从派发到合并约 **10 分钟**（含读文档、实现、自检、交付、评审、合并、收尾） |
| 产出 | PR **#28**（MERGED，squash `ef7f602`）；Issue #27 CLOSED/COMPLETED；新增 `scripts/report.sh`（226 行）+ PLAYBOOK 更新；附带 Bug **#29** |

## 2. 五项验收标准的逐条判定

| # | 标准 | 判定 | 依据 |
|---|---|---|---|
| 1 | 全程无需任何口头/聊天补充说明 | ✅ 通过 | 执行者自述"**主流程零猜测**"；全程未提问 |
| 2 | 无需手工修补状态 | ✅ 通过 | 状态全部由 `scripts/status.sh` 驱动：`start.sh`→in-progress、`deliver.sh`→in-review、`review.sh approve`→acceptance、`status.sh done` 收口；`closeout.sh` 第五项（无残留状态标签）通过 |
| 3 | 无孤儿分支 | ✅ 通过 | `closeout.sh` ③④⑤ 全过（远程已删、本地已删、标签已清）；执行者额外做了 `git fetch --prune` |
| 4 | Issue ↔ 分支 ↔ PR ↔ 合并记录链接完整 | ✅ 通过 | `Closes #27` 自动关单；分支名 `slice/27-...` 由 `policy/branch-name` 校验；评审与验收记录完整（`APPROVED` + `/accept`） |
| 5 | 演练前后度量口径不变 | ❌ **未通过** | 执行者发现 `GOVERNANCE §8` 与切片验收标准对"返修率"给了**两个互相冲突的定义**（分母分别是"总切片"与"窗口内已关闭 Issue"），且在脚本注释、W0.5、PR 描述三处标注了分歧而非擅自取舍 |

**第 5 项未通过的处置**：`GOVERNANCE §8` 已重写为**唯一口径**（窗口语义显式、分母为 0 时输出 `n/a`、在途明确含 `backlog` 单列），`report.sh` 的注释与之逐字对齐。修复随切片 #30 交付。

## 3. 执行者报告的关键命令序列（原文摘要）

```
scripts/toolcheck.sh                                 # 8 项全过
（读 PLAYBOOK / GOVERNANCE / TOOLING / AGENTS + scripts/*.sh）
scripts/status.sh --check ; gh issue list --state open --json ...
scripts/start.sh 27 --dry-run ; scripts/start.sh 27   # gh issue develop + 指派 + 开工声明 → in-progress
（实现 scripts/report.sh；chmod +x）
bash -n scripts/*.sh ; （Python 等价复算 ci/lint 两条正则 → 0 违规）
scripts/report.sh ; scripts/report.sh --days 7 --json | jq -e .
（假 gh shim + 合成数据：跨周分桶 / not_planned 排除 / status 违规告警）
scripts/deliver.sh 27 --prepare → 填写正文 → scripts/deliver.sh 27   # PR #28 → in-review
gh pr checks 28 --required                            # ci/lint, ci/test, policy/* 全 pass
scripts/review.sh 28 approve --body-file ...          # → acceptance
scripts/review.sh 28 accept  --body-file ...
gh pr merge 28 --squash --delete-branch
scripts/status.sh 27 done ; scripts/closeout.sh 28     # 五项全过
gh issue create ... → #29（按 AGENTS §5 开 Bug，不顺手改）
```

## 4. 演练发现的缺陷与处置

| # | 发现 | 类型 | 处置 |
|---|---|---|---|
| 1 | `lib.sh` 的 `die "消息" 2` 输出 `[FAIL] 消息 2`（退出码被 `$*` 拼进消息） | 脚本缺陷 | **Bug #29** → 已于切片 #30 修复并验证（消息与退出码分离） |
| 2 | `REPO` 在 `source lib.sh` 阶段解析，残留失效 `GH_TOKEN` 会直接失败（`GH_TOKEN=bogus bash scripts/audit.sh`） | 脚本缺陷 | **Bug #29** → 已在 `lib.sh` 修复（解析时临时清空 `GH_TOKEN` 再恢复），并写入 PLAYBOOK §4 |
| 3 | **返修率存在两个冲突定义** | 文档缺陷（验收标准 5 未通过） | §8 重写为唯一口径 + `report.sh` 注释对齐（切片 #30） |
| 4 | "在途是否含 backlog" 无明文 | 文档缺口 | §8 明确：`backlog` 单列，二者合计 = 开放 Issue 总数 |
| 5 | `mergeStateStatus=UNSTABLE` 是否可合并未说明 | 文档缺口 | PLAYBOOK §8 补：**UNSTABLE 不是卡点**，只有 `BLOCKED` 才是 |
| 6 | 本机 BSD `grep` 无 `-P`，无法逐字复现 `ci/lint` | 文档缺口 | PLAYBOOK §4 补：本地用 Python 等价复算，以 CI 为准 |
| 7 | 合并后 `git branch -a` 仍列已删远程分支 | 文档缺口 | PLAYBOOK §4 补：`git fetch --prune`；判定远程分支必须用 `git ls-remote` |
| 8 | `--days` 窗口边界（`closed:>=DATE` 含起始日整天）未定义 | 文档缺口 | §8 显式写明窗口语义 |

## 5. 文档有效性结论

**有效**：`PLAYBOOK` W0–W12 的命令链完整，`start/deliver/review/closeout` 每步一条命令即可推进；
门禁清单、两条硬规则、PR 卡死排查表、环境陷阱（bash 3.2 / `sed -E` / gh 坑）都在写代码前生效；
W7 明确"先 approve 解锁合并、再留 `/accept`（非阻塞）"，因此执行者没有去等非必需检查。

**不足与改进**：见上表 8 项，其中 2 项为脚本缺陷、1 项为口径二义（验收未过）、5 项为说明缺失。全部已修复或登记。

**方法论结论**：**门禁与流程类改动必须实测**。第一次演练（半程中止）暴露了"状态迁移无人负责"与"文档与实现不符"；
第二次演练（完整闭环）又暴露了 `lib.sh` 两处尖锐行为与口径二义。这些都不可能靠纸面评审发现。

## 6. 与第一次演练的对比

| | 第一次（切片 #20） | 第二次（切片 #27） |
|---|---|---|
| 结果 | **半程中止**（PM 架构变更作废目标） | **完整闭环**（PR 合并 + 收尾五项全过） |
| 有效证据 | 认领 → 建分支 → 开工声明（`HANDOFF:v1` 格式完全一致） | 全流程 |
| 主要发现 | 状态迁移无归属、`policy/branch-name` 文档与实现不符 | `lib.sh` 两处缺陷、返修率口径二义、5 处说明缺失 |

两次演练共同证明：**文档能支撑陌生执行者完成主干流程**；而"文档承诺 vs 系统实际"的偏差需要演练才能暴露。
