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
- **判据**：`preflight.sh` 第 ⑧ 组的 CODEOWNERS 完整性断言 —— 每个 owner 是协作者**且有 push**／评审身份是 `*` 规则的 owner／合并身份是协作者；`require_code_owner_review` 的**开关取值只读线上实测值**（仓库内 JSON 是声明，不是真值），开关未开启时该条降级为提示、不误报；解析不出评审身份 → 失败（fail-closed）。反向样本（R1 删掉 `*` 规则里的评审身份／R2 加入非协作者 owner）**必须失败**。

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
- **判据**：`preflight.sh` 与 `ci/test` 用同一判据（`LABEL_ASSERT` 标记区）断言存在；必需集合 = **手写机器清单**（`MACHINE_LABELS`：`status/*`×3 + `type/*`×4）∪ **Issue 表单预置项**（从 `.github/ISSUE_TEMPLATE/*.yml` 的 `labels:` 解析，不手抄，解析不出 → 失败）；反向样本覆盖两类（R3 缺模板预置项、R3b 缺手写项与真模板项）→ 断言**必须失败**。

**13. 凭据隔离的能力边界：文件隔离只是提高门槛，不是防线本身**
- **禁止**：宣称"作者取不到评审凭据"或任何等价说法；完整边界见 [identity.md](identity.md)「隔离的能力边界」。

**14. `set -o pipefail` 下禁止 `printf … | grep -q`（EPIPE 让管道整体判失败）**
- **禁止**：在 `set -o pipefail` 的脚本里用「`printf` 经管道接 `grep -q`」—— `grep -q` 命中即退出，写端收到 `EPIPE`，管道整体退出码变失败。
- **必须**：判断字符串包含时用 here-string：`grep -q … <<<"$var"`（无管道 → 无 EPIPE）；需要过滤行时同理（`head`/`sed` 的输出先进 `$(…)` 或临时文件）。
- **判据**（常驻 `ci/test`，不新增必需检查）：大正文双向反向样本（含关键字必须通过 / 不含必须失败）+ 工作流静态扫描「管道接 `grep -q`」零命中。

**15. macOS bash 3.2.57 的 `read -t 0` 不可用（有数据也返回 1）**
- 触发：想检测 stdin 是不是**管道输入**（`read -t 0` 在 3.2.57 上无论有无数据都返回 1）。
- **禁止**：用 `read -t 0` 判定"有没有管道输入"；也**禁止**拿它当超时读。
- **必须**：改用 `/dev/stdin` 的**类型判定** —— `[ -p /dev/stdin ]`（管道）/ `[ -f /dev/stdin ]`（重定向的普通文件）/ `[ -t 0 ]`（终端），据此分支。
- **判据**：❌ 无静态扫描（`ci/lint` 只扫 bash 4 特性）；行为差异**必须**用两种真实调用（管道 / 非管道）作反向样本证明。

**16. `gh issue create -T <form>.yml` 在非交互下不可用**
- 触发：脚本 / 非交互环境里用 `-T`（`--template`）建 Issue —— `--template` 与 `--body` / `--body-file` **互斥**，必失败。
- **禁止**：非交互场景用 `-T`；**禁止**省略标签后指望表单自动补（表单只在网页端建单时生效）。
- **必须**：`--body-file <文件>` + **显式 `--label`**（把表单 `labels:` 的值显式列出）。
- **判据**：❌ 无直接判据（本仓库脚本不建 Issue）；相邻判据 = 陷阱 12 的标签存在性断言 —— `--label` 传不存在的标签会**当场失败**，不静默。

**17. `NL="$(printf '\n')"` 得到空串 → 反向样本会静默退化成正向样本**
- 触发：用命令替换取一个换行符当分隔符 / 构造反向样本（`$(…)` 吃掉尾换行 → `NL` 是**空串**）。
- **禁止**：用 `$(printf '\n')` 拼分隔符或反向样本 —— 退化后反向样本与正向样本**相同**，断言恒真（空断言）。
- **必须**：用 bash 字面量 `$'\n'`（bash 3.2 支持）；构造反向样本后**必须**自检「两样本确实不同」（计数 / `diff`）。
- **判据**：❌ 无静态扫描；**必须**在用例内自带"两样本不同"的自检（本仓库做法：`grep -c … ` 分别在两样本上取 1 与 0）。

**18. 字节级往返不能用 `$()` / `jq -r`（吃 / 补尾换行）**
- 触发：要证明两份文本**逐字节相同**（文档 ↔ 脚本判据、仓库内规则集 ↔ 线上响应）。
- **禁止**：`a="$(cat f1)"; b="$(cat f2)"; [ "$a" = "$b" ]` —— `$(…)` 吃掉尾换行，`jq -r` 还会**补**一个。
- **必须**：**落文件 + `cmp`**（或 `diff`）比较；确实要让 jq 输出参与比较时用 `jq -j`（不补换行）。
- **判据**：✅ 常驻 `ci/test`：标记区/判据的「唯一来源」断言（`RULESET_CANON_JQ`、`WORKSPACE_ASSERT`、`LABEL_ASSERT`、`TRANSITIONS`）都靠"抽出同一段文本再比对"实现，**不允许**第二份实现；抽不到 / 过短 → 直接 `::error::`（fail-closed）。完整文件的字节级相等仍需 `cmp`。

**19. 依赖 slug / 身份 / 线上值的断言必须 fail-closed**
- 触发：`gh repo view` 在 **remote 不是 GitHub URL**（或无 remote / 未登录）时解析不出 slug —— 解析失败若被当成"跳过"，P6 链接一致性、规则集 diff、标签存在性、CODEOWNERS 完整性等断言会**静默放行**。
- **禁止**：把"取值失败"当成"无需断言"；**禁止** `… || true` 吞掉失败后照常打印 `[ OK ]`。
- **必须**：取不到值 / 取到空值 → `[FAIL]`，并在原文里区分「取不到值」与「值不一致」；不得用 `[ OK ]` 放行。
- **收尾同样必须 fail-closed**：`closeout.sh` 的远端查询只有匹配结果（退出 0）或无匹配 ref（退出 2）可判定；其他退出码是查询失败。Issue 标签读取及清理后回读必须成功才可核验“无残留”，失败不写恢复记录、不删尚在的本地分支。`ci/test` 的真实脚本 fixture 包含远端退出 128、标签读取失败、清理后回读失败三类反向样本。
- **判据**：✅ `scripts/preflight.sh`（锚点：`无法确定仓库 slug`；`CODEOWNERS 的 owner 不是协作者`；`无法从 references/identity.md 的三身份表解析出评审身份`）—— slug 取不到：`bad "无法确定仓库 slug（gh repo view 失败）"`；CODEOWNERS 解析不出 owner：`[FAIL]`；评审身份解析不出：`[FAIL]`。反向样本：把 remote 临时换成非 GitHub URL 后重跑 → 必须 `[FAIL]`。

**20. 正文「标题行」的判据是 ATX 形态 `^#{1,6}[[:space:]]`，不是 `^#`**
- 触发：对 PR / Issue 正文做「空小节」长度校验，用 `/^#/ { next }` 跳过标题行。
- **禁止**：用 `^#`（"以 `#` 开头即标题"）—— 正文里**引用 Issue / PR 号是常态**（`#152 引入了…`、`见 #45`），这类行是正文，不是标题。
- **必须**：只有井号**后面紧跟空白**才算标题（`^#{1,6}[[:space:]]`）；小节边界行（`## 1.`–`## 6.`）由**排在前面的**那条规则单独处理，不要与标题规则合并。
- 后果：被误判的行不计入该节长度 → 该节被当空 → `[FAIL] 以下章节内容过少（需要真实填写）`（fail-closed 在推送前，无副作用；#156 / PR #162 真实撞到，见 #163）。
- **判据**：`scripts/deliver.sh` 的 `empty_sec` awk（无独立测试套件，反向样本贴在 #163 的 PR 正文第 4 节，逐条真实输出）：(a) 小节首行 `#152 引入了…` → **通过**（改前 FAIL）；(b) 小节首行 `见 #45` → 通过（改前也通过，属"不得回归"样本）；(c) 小节内容**只有**真正的标题行 → 仍判空 `[FAIL]`（证明标题仍被跳过）；(d) 小节**确实为空** / 内容不足 20 字 → 仍 `[FAIL]`（**不得** loosening 成永远通过）；(e) 同一输入喂**基线**脚本 → `[FAIL]`（证明修的是真缺陷）。
- 同类形态扫描：`scripts/preflight.sh`（锚点：`sub(/[ \t]+#.*$/, "", v)`）里的 YAML 行内注释剥离 **不属于本类** —— 它要求 `#` **前面有空白**，正是 YAML 注释的判别条件，`ref#152`、`"#152"` 之类的值不会被吞（实测见 #163 的 PR）。

**21. 需要长期准确的引用必须写「符号锚点」，不得只写 `file:line`（行号会静默漂移）**
- 触发：在文档里定位另一个文件的某段内容（替换点清单、判据出处、命令样例），或用一个**会继续增长**的文件的行号做引用。
- 后果：上游插入 / 删除行后，引用**静默**指到别的正文 —— 行号仍"在文件范围内"，`grep` / `preflight.sh` / `ci/test` 都不会报。实测（#154）：`SKILL.md` 的安装路径行从 58 漂到 70、`references/flow.md` 的作者身份样例行从 51 漂到 52；`references/portability.md` 里指向 job `name:` 的行号也已指向别的行（#160 之前无人发现）。
- **禁止**：把 `path:line` 当**唯一**定位，尤其是 `references/portability.md` / `references/bootstrap-checklist.md` 的替换点清单 —— 这两处**零命中**。
- **必须**：引用写成两段 —— 先给路径，再给锚点标记（全角括号 + 锚点 + 反引号括起的字面文本）；锚点是**目标文件里已经存在**的片段（标签 / 键名 / 结构标记，**不是**新发明的标记），且优先选**不会随替换一起消失**的文本（如 `DEVELOPER_PAT_FILE=` 这类键名）。确需行号时，同一行**必须**同时给锚点（行号只做定位，锚点做判据）。
- **判据**：✅ `ci/test` 的「替换点清单的符号锚点」step —— (a) 两份清单零 `path:line` 形态；(b) 每个锚点在目标文件里**逐字存在**（缺失 → `FAIL` 并指出条目 + 文件）；(c) 其余文档里含 `path:line` 的行必须**同行**带锚点。反向样本（锚点字面文本改掉 → 必须 `FAIL`；清单里塞回 `path:line` → 必须 `FAIL`；其它文档塞入不带锚点的 `path:line` → 必须 `FAIL`；恢复 → 通过；**同一变异输入在基线** `4679a9e` **上不报**）逐条贴在 #160 的 PR 正文。

**22. 标准合并会先删除本地分支，收尾不能据此跳过恢复锚点**
- 触发：`gh pr merge --squash --delete-branch` 已删除本地分支，随后跑 `scripts/closeout.sh`。
- **禁止**：把“本地分支不存在”当成“已留恢复锚点”；在缺 SHA、评论读取/写入/回读失败时报通过。
- **必须**：每个关联 Issue 都核验本 PR head + squash SHA 的记录，缺失则写入并回读；本地 tip 不可得须明说，恢复用 `git fetch origin refs/pull/<pr#>/head`。已有记录时幂等零写入；dry-run 不写锚点、不删分支，尚缺任何一项即失败。
- **判据**：`ci/test` 的“收尾恢复锚点回归”用 stub `gh` 和真实 Git fixture 跑真实 `closeout.sh`，覆盖缺分支、两 Issue、先记录后删分支、幂等、dry-run、读写失败、回读不一致、缺 SHA、未合并、远端/标签查询失败、清理后回读失败保全十三项；同一缺分支输入在修复前缺锚点，修复后有两份可恢复记录。
