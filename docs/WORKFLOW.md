# WORKFLOW — 多 agent + GitHub 开发工作流

> [README](../README.md) 讲本质，[AGENTS.md](../AGENTS.md) 讲契约，本文件讲**步骤与判据**。
> 三者冲突时：**GitHub 平台实际行为 > 本文件 > AGENTS.md**。发现冲突要开 Issue 改文档，而不是按"更方便"执行。

---

## 0. 三身份

| 角色 | 账号 | 凭据 | 能做什么 |
|---|---|---|---|
| 作者 | `@yes8080-dev-bot` | `.secrets/developer.pat`（`repo, workflow`） | 建分支、提交、推送、开 PR、返修 |
| 评审 | `@yes8080-reviewer-bot` | `.secrets/reviewer.pat`（`repo`） | `approve` / `request-changes` |
| 合并 | `@yes8080` | 本机 `gh auth login` 登录态 | **只有它**能合并与改仓库设置 |

- 身份由**平台**强制：GitHub 禁止自我批准 → 作者 approve 必然失败。
- 作者凭据的 `workflow` scope 是硬依赖：缺它时推送任何 `.github/workflows/**` 改动会被服务端**整体拒绝**
  （原文 `refusing to allow a Personal Access Token to create or update workflow ... without 'workflow' scope`）。
- 评审凭据失效 = `.github/**`、`scripts/**`、`docs/**` 永久无法合并（`require_code_owner_review`）。`preflight.sh` 会拦。

---

## 1. 状态机（唯一源）

```
Backlog(无 status/* 标签) → ready → in-progress → in-review → acceptance → Done(PR 合并自动关单)
                                             ↘ rework（打回，同一分支继续提交）
```

| 状态 | 载体 |
|---|---|
| backlog | 无 `status/*` 且 Issue OPEN |
| ready / in-progress / in-review / acceptance / rework | 对应 `status/*` 标签，**互斥** |
| done / canceled | Issue CLOSED（`state_reason` = completed / not planned），并**清空**状态标签 |

- 迁移**只能**走 `scripts/status.sh <issue#> <state>`。
- `done` / `canceled` 有两个载体：Issue `CLOSED` **且**无任何 `status/*` 标签。`status.sh` 的幂等判断两者都核 ——
  已关闭但仍有残留标签时，它会继续清理而不是短路返回。
- 体检：`scripts/status.sh --check` 扫全部开放 Issue，每个必须 0 或 1 个 `status/*`；`ci/test` 每次 PR 也跑同一不变量。

---

## 2. W0..W7 闭环

### W0 · 预检（每次接手都跑）

```bash
scripts/preflight.sh
```

判定：全部 `[ OK ]` 才继续。任何 `[FAIL]` → 把原文报告 dispatcher，**不要"先干着看"**。
它检查：命令齐备 / gh 登录 / cwd 在仓库内且非 worktree / 工作区状态 / 远端唯一 origin /
三身份凭据可用且**两两不同** / 作者凭据含 `workflow` scope / 凭据未入库且权限 600 /
线上规则集与 `.github/rulesets/main-protection.json` 的必需 context 一致 / 每个必需 context 都有工作流 job。

### W1 · 领片（DoR）

```bash
gh issue list --state open --label status/ready --limit 20 --json number,title,labels
```

DoR（五项全齐才可从 Backlog → `ready`）：
① 价值一句话 ② 可判定的验收标准 ③ 明确不改什么（边界）④ 依赖与契约 ⑤ 规模与执行者。

### W2 · 开工

```bash
scripts/start.sh <issue#> --as author
```

做四件事：校验 Issue OPEN 且无未关闭阻塞 → `gh issue develop` 建分支并**绑定** Issue →
指派给作者 → 留开工声明 → 迁移到 `in-progress`。

分支名：`<type>/<issue#>-<slug>`，`type ∈ {slice,fix,hotfix,spike,chore}`，slug 只允许 `[a-z0-9-]`。
`policy/branch-name` 会**逐字**校验这条正则，并要求 Issue OPEN 且已有 `status/*` 标签。

### W3 · 实现与提交

```bash
bash -n scripts/*.sh
git -c user.name="yes8080-dev-bot" \
    -c user.email="317173623+yes8080-dev-bot@users.noreply.github.com" \
    commit -F /tmp/msg.txt
```

- 提交者身份必须**显式**指定（`--as author` 只切 `gh` 的 API 身份，不改 git 身份）。
- 提交信息用 `-F <文件>`：带反引号/多行的信息内联进命令行会被 shell 吃掉。
- 收尾前工作区必须干净（`deliver.sh` 会拦）。

### W4 · 交付 PR

```bash
scripts/deliver.sh <issue#> --prepare --as author   # 生成六段骨架到 .git/PR_BODY_<N>.md
#   填写骨架（第 4 节必须是可核对证据）
scripts/deliver.sh <issue#> --as author             # 校验 → 推送 → 建 PR → 状态 in-review
```

判定（本地预演门禁，与 `policy/*` 同一套）：
- 正文含关闭关键字（`Closes #N`）——**PR 标题里的关键字无效**
- 正文含 `## 1.` … `## 6.` 六段，且每段有实质内容
- 分支名合规且分支里的 issue 号 = 传入的 issue 号

若该分支**已有** PR（返修场景）：`deliver.sh` 只推送并用 REST PATCH 更新正文（见 §已知陷阱「不要用 `gh pr edit`」）。

### W5 · 必需检查（5 个，逐字）

```bash
gh pr checks <pr#> --required
```

| context（= job `name:`） | 判什么 |
|---|---|
| `ci/lint` | 全部被跟踪脚本的 `bash -n` + bash 3.2 兼容（禁 bash4 特性、`$VAR` 后不得紧跟中文）+ JSON 有效 |
| `ci/test` | 关键不变量：5 个 context 与工作流 job 名**精确相等**、规则集形状、状态标签互斥、PR 模板六段、无凭据入库、脚本自包含 |
| `policy/linked-issue` | PR 正文有 `Closes #N` **且** GitHub 解析出了关闭关系（目标必须是默认分支） |
| `policy/branch-name` | 分支名匹配正则 + Issue OPEN + 已有 `status/*` 标签 |
| `policy/template` | PR 正文有 `## 1.` … `## 6.` |

全部 `pass` 才能进入 W6。若某项永久 `pending` → 看 §已知陷阱第 1、2 条。

### W6 · 独立评审

```bash
scripts/review.sh <pr#> approve --body-file review.md      # 或 request-changes --body-file ...
```

- 必须由 `@yes8080-reviewer-bot`（`review.sh` 用评审凭据，**不加** `--as`）。
- 评审通过 → Issue `acceptance`；打回 → `rework`（在**同一分支**继续提交，不新建分支/PR）。
- `require_last_push_approval`：返修后新推送会**驳回旧批准**，必须重新评审。

### W7 · 合并与收尾（dispatcher）

```bash
gh pr merge <pr#> --squash --delete-branch     # 只有 @yes8080 能做
scripts/closeout.sh <pr#>                      # 五项核验
```

`closeout.sh` 五项：① PR 已 MERGED ② 关联 Issue 已关 ③ 远端无头分支 ④ 本地无头分支已清理 ⑤ 无残留状态标签。
其中第 ④ 项**先**把「分支名 + 本地 tip SHA + PR head SHA + squash 提交」写进 Issue 作为可恢复锚点，**再**用
`git branch -D` 删除（squash 合并后原始提交不在 `main` 上，`-d` 必然拒绝；但绝不允许无条件 `-D`）。

### 返修

评审打回 → 状态 `rework` → 作者在**同一分支**提交 → `scripts/deliver.sh <issue#> --as author`（更新正文/推送）
→ 状态回 `in-review` → 重新评审。**不要**新建分支或 PR。

---

## 3. DoD（什么算做完）

- [ ] Issue 的验收标准**逐条**有可核对证据（命令 + 输出 / 检查名 / 运行链接）
- [ ] 5 个必需检查在该 PR 的**最新 SHA** 上全部通过
- [ ] 至少 1 名非作者 code owner 批准（`reviewDecision=APPROVED`）
- [ ] PR 正文六段齐备，第 3 节回滚方式**可执行**
- [ ] 未越界：只改了 Issue「边界」内的内容
- [ ] `closeout.sh` 五项全过（合并后由 dispatcher 跑）
- [ ] 新增的坑已写进本文件 §已知陷阱

---

## 4. 已知陷阱（均有原始证据，别再踩）

1. **必需检查不能"先失败后通过"。** 一旦某个必需 check 在某个 SHA 上留下 `FAILURE`，**后续同名检查
   通过也无法解除阻塞**（实测：`reviewDecision=APPROVED` + 全部 checks 最新一次 success，仍 `BLOCKED`；
   把失败的必需项移出必需清单后立刻可合并）。→ 因此验收门禁只用**原生规则**
   （`required_approving_review_count: 1` + `require_last_push_approval` + `dismiss_stale_reviews_on_push`），
   不做成"先必然失败、批准后才通过"的检查。
2. **必需检查的 context = 工作流里 job 的 `name:`**，不是文件名、不是 workflow `name:`。
   把 job 的 `name:` 改名 = 所有 PR 永久 pending。
   也不要给必需检查工作流加 `paths`/`branches` 过滤：被跳过的工作流 = 检查永久 pending。
   更不要用 `issue_comment` 触发：官方只认 `push`/`pull_request`/`pull_request_review`/`pull_request_target`/
   `deployment`/`deployment_status`（合并队列另加 `merge_group`）。
3. **`merge_group` 未接线。** 本仓库私有且非 GHEC，Merge Queue 不可用，故 5 个 job 只监听 `pull_request`。
   若将来启用 Merge Queue，**必须**同时给 5 个 job 接上 `merge_group`，否则合并队列会因必需检查未上报而永久卡住。
4. **规则集目标只能用 `~DEFAULT_BRANCH`，不得用 `**`。** 官方：分支保护/仓库规则可能阻止「自动删除头分支」，
   写通配符会导致切片分支合并后删不掉。
5. **`git push --dry-run` 不能用来判断规则集是否生效。** dry-run 不评估 repository rules。真正阻止直推
   `main` 的是 `pull_request` 规则（原文：`push declined due to repository rule violations`）。
6. **CODEOWNERS 里任何会被改动的路径都必须至少有一个"非作者" owner。** 若某路径 owner 只有作者本人而
   `require_code_owner_review=true`，该路径的改动**永久无法合并**。且 CODEOWNERS **取自目标分支** ——
   在 PR 里改它无法为该 PR 自己解锁。
7. **作者的 classic PAT 只有 `repo` + `workflow`，没有 `read:org`。** `gh pr edit` 走 GraphQL、需要 `read:org`
   → 会报 `Your token has not been granted the required scopes ... 'read:org'` 且**静默不更新正文**。
   改 PR 正文必须用 REST：`jq -Rs '{body:.}' file | gh api -X PATCH repos/$REPO/pulls/$N --input -`，
   并在写后**回读校验**（`deliver.sh` 已封装）。
8. **推送必须清掉本地 credential helper。**
   `git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin <branch>`
   —— 否则 macOS 钥匙串里缓存的主身份凭据会优先命中，"作者身份推送"会静默变成主身份推送。
9. **macOS 自带 bash 是 3.2。** 禁 `mapfile`/`readarray`/`declare -A`/`${var,,}`；`$VAR` 后紧跟中文等多字节
   字符必须写 `${VAR}`，否则字节序列被并入变量名 → `unbound variable`。
   `sed` 是 BSD 版：扩展正则要用 `sed -E`（BRE 的 `\+` 会被当字面量）。
10. **`blockedBy` 不会因对方关闭而自动清除。** 判定"是否真被阻塞"必须看 blocker 的 `state`。
11. **squash 合并后 `git branch -d` 必然拒绝**（原始提交不在 `main` 上）。先验证 PR=MERGED，留锚点，再 `-D`；
    绝不无条件 `-D`（那会掩盖"PR 未合并就删分支"的真实错误）。
12. **流程只在仓库里。** `docs/WORKFLOW.md` + `AGENTS.md` + `.github/**` + `scripts/**` 就是全部权威流程描述；
    不引入第二套规范文档，也不发布"可移植治理套件"。元工具自身的代码量超过它服务的开发工作，就是失控信号。

---

## 5. 明确不做（边界）

不做「装到别人仓库」（无安装器/卸载器）｜不做 Projects｜不做度量报表｜不做跨模型评审留痕｜不做能力开关｜
不做共享库（每个脚本自包含）｜不做要求审批才能通过的自定义验收检查。
**理由：本项目的价值是"多 agent 用 GitHub 跑开发"，不是发布工具。**
