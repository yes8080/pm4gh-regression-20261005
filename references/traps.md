# traps — 已知陷阱（纯规则）

> **何时读**：现象对得上下面某条触发条件时。先查这里再动手，不要凭直觉绕过门禁。

**1. 必需检查不能"先失败后通过"**
- 触发：某必需检查已在某个 SHA 上留下 `FAILURE`，之后同名检查通过。
- **禁止**：把验收做成自定义检查；用 `/accept` 评论代替批准。
- **必须**：验收门禁只用原生规则（`required_approving_review_count: 1` + `require_last_push_approval` + `dismiss_stale_reviews_on_push`）。
- 后果：失败结论在**该 SHA 上不可逆**，阻塞解除不了 → 报告 dispatcher，不要绕过。

**2. 必需检查的 context = 工作流里 job 的 `name:`**
- 触发：改了某个 job 的 `name:`、给必需检查工作流加过滤、换触发事件。
- **禁止**：改 `name:`（不是文件名、不是 workflow `name:`）；加 `paths` / `branches` 过滤（被跳过的检查 = 永久 pending）；用 `issue_comment` 触发（官方只认 `push` / `pull_request` / `pull_request_review` / `pull_request_target` / `deployment` / `deployment_status`）。
- **必须**：若启用 Merge Queue，同时给 5 个 job 接上 `merge_group`（现在**未接线**）。

**3. 规则集只能按「整份」比对，目标只能用 `~DEFAULT_BRANCH`**
- 触发：想用通配符，或用 `git push --dry-run` 判断规则集是否生效。
- **禁止**：`**` 通配符（会让切片分支合并后删不掉）；挑字段比对；用 `git push --dry-run`（它**不评估** repository rules）。
- **判据**：唯一判据是 `RULESET_CANON_JQ` **全量键 diff**（`preflight.sh` 与 `ci/test` 逐字同一段文本）。
- **禁止**：改线上规则集或 `.github/rulesets/main-protection.json`（属 dispatcher 权限）。
- 备注：`require_extra_approval_for_unattributed_changes` = 含**无法归属到 GitHub 身份**的提交时需**额外批准**（这类 PR 可能要求多于 1 个批准）。

**4. CODEOWNERS 里任何会被改动的路径都必须至少有一个"非作者" owner**
- 触发：某路径 owner 只有作者本人，而 `require_code_owner_review=true`。
- 后果：该路径改动**永久无法合并**（GitHub 禁止自我批准）。
- **禁止**：在 PR 里改 CODEOWNERS 为**该 PR 自己**解锁 —— CODEOWNERS 取自**目标分支**。

**5. 作者的 classic PAT 只有 `repo` + `workflow`，没有 `read:org`**
- 触发：用 `gh pr edit` 改 PR 正文 → 报 scope 错且**静默不更新**。
- **必须**：改正文用 REST `jq -Rs '{body:.}' <文件> | gh api -X PATCH repos/$REPO/pulls/$N --input -`，并**回读校验**（`deliver.sh` 已封装）。

**6. 推送必须清掉本地 credential helper**
- 触发：直接 `git push`。
- **必须**：`git -c credential.helper= -c credential.helper='!gh auth git-credential' push -u origin <branch>`。
- 后果：macOS 钥匙串里的主身份凭据优先命中，作者身份推送**静默**变成主身份推送。

**7. macOS 自带 bash 是 3.2**
- **禁止**：`mapfile`、`readarray`、`declare -A`、`${var,,}`。
- **必须**：`$VAR` 后紧跟中文写 `${VAR}`（否则 `unbound variable`）；BSD `sed` 扩展正则加 `-E`。

**8. `blockedBy` 不会因对方关闭而自动清除**
- 触发：判定"是否真被阻塞"。
- **必须**：看 blocker 的 `state`（`start.sh` 已按 `state=OPEN` 判定）。

**9. squash 合并后 `git branch -d` 必然拒绝**
- 触发：原始提交不在 `main` 上时用 `-d`。
- **必须**：**先**验证 PR=MERGED、留可恢复锚点，**再** `-D`。**禁止**无条件 `-D`。

**10. 状态迁移的判据是「HTTP 层单请求」，不是「一次 CLI 调用」**
- 触发：想改回 `gh issue edit` 或多次写调用。
- **必须**：带标签 → 带标签的迁移只有**一条** HTTP 写请求 —— REST `PUT /repos/{owner}/{repo}/issues/{n}/labels`（整份替换）；实现只在 `status.sh` 的 `STATUS_LABELS_PUT` 标记区（读 → 改 → 写 → 读回校验）。
- **禁止**：`gh issue edit`（HTTP 层是 add/remove 两个**并发** mutation，中间态可能是 0 或 2 个 `status/*`）。
- **必须**：载荷带上读到的**全部非 `status/*` 标签**（`type/*`、`role/*`…）—— 整份替换只发 `status/*` 会**静默删掉**别人的标签。
- **必须**：写后**读回校验**一次；非 `status/*` 集合不一致 → **报告并退出、不重试覆盖**。
- 三类载荷：带标签→带标签 = 非 `status/*` + 目标标签；→ `backlog` = 非 `status/*`；→ `done` / `canceled` = 非 `status/*`，**先**整份替换、**后** `gh issue close`。
- **判据**（常驻 `ci/test`，不新增必需检查）：stub `gh` 跑**真实** `status.sh` —— 非终态迁移**恰好 1 次**写请求、0 次 `gh issue edit`、载荷含全部非 `status/*` 标签；反向样本（两次写请求 / 漏带 `type/*`）**必须失败**。
- 后果：`policy/branch-name` 对 0 或 2 个状态标签都判失败，失败的 SHA **不可逆**（见陷阱 1）。

**11. tab 当字段分隔符会静默吞掉空字段**
- 触发：`IFS="$(printf '\t')" read -r a b c` 遇到连续 tab（tab 属 IFS 空白，连续空白只算一个分隔符）。
- **必须**：脚本内部的记录分隔用**非空白字符**（本仓库用 `|`）或给空值写占位符。
- **判据**：这类差别**必须**能用反向样本抓到。

**12. Issue 表单不会打标签，标签也没有清单**
- 触发：`bug.yml` 的「轨道」下拉选「线上故障」—— 它**不会**打 `type/hotfix`，而 `start.sh` 靠 `type/*` 推导分支类型。
- **必须**：线上故障用 `scripts/start.sh <issue#> --type hotfix --as author`，或先手动加 `type/hotfix` 标签。
- 后果：热修**静默**退化成 `fix/`。
- **判据**：机器消费的标签由 `preflight.sh` 与 `ci/test` 用同一判据（`LABEL_ASSERT` 标记区）断言存在，并带反向样本（删掉 `type/hotfix` → 断言必须失败）。

**13. 凭据隔离的能力边界：文件隔离只是提高门槛，不是防线本身**
- **禁止**：宣称"作者取不到评审凭据"或任何等价说法；完整边界见 [identity.md](identity.md)「隔离的能力边界」。

**14. `set -o pipefail` 下禁止 `printf … | grep -q`（EPIPE 让管道整体判失败）**
- **禁止**：在 `set -o pipefail` 的脚本里用「`printf` 经管道接 `grep -q`」—— `grep -q` 命中即退出，写端收到 `EPIPE`，管道整体退出码变失败。
- **必须**：判断字符串包含时用 here-string：`grep -q … <<<"$var"`（无管道 → 无 EPIPE）；需要过滤行时同理（`head`/`sed` 的输出先进 `$(…)` 或临时文件）。
- **判据**（常驻 `ci/test`，不新增必需检查）：大正文双向反向样本（含关键字必须通过 / 不含必须失败）+ 工作流静态扫描「管道接 `grep -q`」零命中。
