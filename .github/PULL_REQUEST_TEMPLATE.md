<!--
  六段结构由 policy/template 必需检查强制；第一行的关闭关键字由 policy/linked-issue 强制。
  注意：关闭关键字只在 PR **正文或提交信息**里生效，**PR 标题无效**。
  判据与步骤见 SKILL.md 与 references/flow.md。
-->

Closes #

## 1. 变更摘要

<!-- 必须写：改了什么、解决了什么问题。评审人只看这里就该知道改动意图。 -->

## 2. 影响面

<!-- 受影响的功能/模块/接口/数据/配置；与其他切片的关系；兼容性说明 -->

- 受影响范围：
- 是否有破坏性变更：否 / 是（若是，加 `risk/breaking` 标签并写迁移与回滚）
- 是否需要数据迁移：否 / 是

## 3. 回滚方式

<!-- 必须可执行：revert 本 PR / 恢复配置 / 反向迁移。不允许写"出问题再说"。 -->

## 4. 验收证据

<!-- 与 Issue 的验收标准逐条对应。给确切命令与**真实输出**，或检查名与运行链接。 -->

<!-- C7：每个证据块必须带产生它的 SHA（机器判据 = 围栏外所有标记的 sha == 本 PR head SHA；一块一行，放在围栏外）。
     用 scripts/deliver.sh 写/更新正文时，下面这行的 sha 会被自动改写为推送后的 head SHA；
     手工建 PR 时把它换成 `gh pr view <pr#> --json headRefOid -q .headRefOid` 的值。 -->
<!-- evidence sha=<head> -->

| 验收条目 | 证据（命令 / 检查名 / 输出 / 链接） | 结果 |
|---|---|---|
|  |  |  |

## 5. DoD 自查

- [ ] 验收标准逐条有证据（第 4 节）
- [ ] 5 个必需检查在该 PR 的最新 SHA 上通过（`gh pr checks <pr#> --required`）
- [ ] 文档已更新（涉及流程、接口、运维变更时）
- [ ] 未越界：没有改 Issue「边界」之外的内容
- [ ] 已确认回滚方式可执行（第 3 节）
- [ ] 提交信息遵循 Conventional Commits 并带 Issue 号

## 6. 风险与破坏性变更

<!-- 剩余风险、已知限制、需要后续跟进的事项（若需跟进请新建 Issue 并在此链接） -->

---

<!--
  评审：scripts/review.sh <pr#> approve --body-file review.md（评审身份，不得合并）
  打回：scripts/review.sh <pr#> request-changes --body-file review.md → Issue 转 in-progress，同分支继续提交
  合并：gh pr merge <pr#> --squash --delete-branch（**只有 dispatcher @yes8080 能做**）
  收尾：scripts/closeout.sh <pr#>
-->
