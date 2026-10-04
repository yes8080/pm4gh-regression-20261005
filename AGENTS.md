# AGENTS.md — AI 工具 / Agent 的接手契约

> 本文件是**任何 AI 编码工具或 Agent 参与本项目时必须遵守的契约**。
> 人与 AI 使用同一套流程；AI 不享有"为了效率可以绕过"的豁免。
> 权威流程见 [docs/PLAYBOOK.md](docs/PLAYBOOK.md)，规则见 [docs/GOVERNANCE.md](docs/GOVERNANCE.md)。

---

## 1. 开工前必须做（缺一不可）

```bash
scripts/toolcheck.sh        # 9 项自检（含 git 工作区预检）；任何一项失败就停下来报告，不要"先干着看"
```

然后读三份文档：`docs/PLAYBOOK.md`（怎么做）、`docs/GOVERNANCE.md`（什么算做完）、`TOOLING.md`（怎么交接）。

---

## 2. 必须遵守

1. **一次只做一个切片。** 先领 `Ready` 的切片（`gh issue list --search 'label:status/ready'`），不得同时开多个 `In Progress`。
2. **一个切片 = 一个 Issue = 一个分支 = 一个 PR。** 用 `scripts/start.sh <issue#>` 建分支（它内部走 `gh issue develop`）。
3. **所有改动经 PR。** 禁止直推 `main`（会被规则集拒绝）；禁止用 `--admin` 绕过门禁。
4. **PR 正文必须含 `Closes #<issue#>`**，并填写六段模板（摘要/影响面/回滚/验收证据/DoD 自查/风险）。
5. **必须留可核对的验收证据**：命令、测试名、输出、运行链接。禁止"已测试通过"这类无证据断言。
6. **不得自我批准**（平台也会拒绝）。评审与验收由 `@yes8080-reviewer-bot` 以 `scripts/review.sh` 执行。
7. **遇到门禁阻塞时报告，不要绕过。** 如果门禁本身有缺陷，按 §5 开 Bug Issue 并附证据。

---

## 3. 禁止做的事

| 禁止 | 原因 |
|---|---|
| 直推 / 强推 `main`，删除 `main` | 规则集拒绝；且会破坏线性历史与审计 |
| `gh pr merge --admin` 或任何绕过门禁的手段 | bypass 名单为空；绕过即失去审计意义 |
| 无条件 `git branch -D` | 会掩盖"PR 尚未合并就删分支"的真实错误（Bug #10） |
| 修改 `.github/**`、`scripts/**`、`docs/PLAYBOOK.md`、`docs/GOVERNANCE.md` 后不走 PR | 这些是流程本身，属于治理变更 |
| 改写 `.github/rulesets/main-protection.json` 后直接应用到线上 | 规则集写错会让**所有 PR 卡死**；必须按 PLAYBOOK §9 分阶段并实测 |
| 读取、打印、提交 `.secrets/**` 或任何 token | 凭据泄露；`.gitignore` 已覆盖，`ci/test` 也会扫描 |
| 绕过 `scripts/status.sh` 直接改状态标签，或把状态写进本地文件 | 状态唯一源是 `status/*` 标签 + Issue 开关状态；多处写入会造成状态分裂 |
| 引入自己的流程（自建 TODO 文件、自己的状态机、自己的分支策略） | 违背"流程只在仓库里" |

---

## 4. 标准工作循环

```bash
# 1) 自检
scripts/toolcheck.sh

# 2) 领切片（找 Ready 且指派给自己的）
gh issue list -R yes8080/pm4gh --state open --label role/dev --limit 20 \
  --json number,title,labels

# 3) 开工（建分支 + 指派 + 开工声明）
scripts/start.sh <issue#>

# 4) 实现 + 自检（本地能跑什么就跑什么）
bash -n scripts/*.sh                      # 若改了脚本
bash scripts/audit.sh                     # 漂移审计
git commit -m "feat(scope): 说明 (#<issue#>)"

# 5) 交付
scripts/deliver.sh <issue#> --prepare     # 生成六段骨架
#  填写骨架（必须写真实证据）
scripts/deliver.sh <issue#>

# 6) 等检查 → 由授权身份评审
gh pr checks <pr#> --required
scripts/review.sh <pr#> approve --body-file review.md

# 7) 合并 + 收尾
gh pr merge <pr#> --squash --delete-branch
scripts/closeout.sh <pr#>
```

---

## 5. 失败与异常处理

| 情况 | 正确反应 |
|---|---|
| `toolcheck.sh` 失败 | 停下，把失败项原文报告给 PM；不要跳过 |
| 必需检查永久 pending | 检查工作流是否被 `paths` 过滤跳过、检查名是否被改名（PLAYBOOK §8） |
| `mergeStateStatus: BLOCKED` 但 `reviewDecision: APPROVED` | 疑似"同 SHA 存在失败的必需检查"（PLAYBOOK §7 规则 1）→ 报告，不要绕过 |
| 发现流程缺陷（门禁写错、脚本有坑） | **开 Bug Issue**（复现/期望/实际/影响版本/缓解），不要顺手改掉 |
| 发现需求歧义 | 停下并请求澄清；不要自行扩大范围 |
| 上下文即将耗尽 | 按 TOOLING.md 的交接块写清状态后再退出 |

---

## 6. 一轮工作的完成标准（Definition of Done for an Agent turn）

- [ ] 对应 Issue 已更新（开工声明、进度、证据）
- [ ] 分支已推送，PR 已开且正文含 `Closes #N` 与六段内容
- [ ] 必需检查状态已核对并记录
- [ ] 若已合并：`scripts/closeout.sh` 五项全过（含「无残留状态标签」）
- [ ] 新增/变更的坑已写进 `docs/PLAYBOOK.md` §4 或对应脚本注释
- [ ] 交接块（若需交接）已写入 Issue 评论

---

## 7. 与本契约冲突时的处理

本契约、`docs/PLAYBOOK.md`、GitHub 平台实际行为三者冲突时，优先级为：
**GitHub 平台实际行为 > PLAYBOOK > 本契约**。
发现后必须提 Issue 修正文档，而不是按"更方便"的方式执行。
