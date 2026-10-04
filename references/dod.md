# dod — 完成标准（DoD）

> **何时读**：写 PR 正文第 5 节「DoD 自查」时；dispatcher 合并前核验时。

- [ ] Issue 有开工声明与进度评论；验收标准**逐条**有可核对证据（命令 + 输出 / 检查名 / 运行链接）
- [ ] 分支已推送、PR 已开且正文含 `Closes #N` 与六段；第 3 节回滚方式**可执行**
- [ ] 5 个必需检查在该 PR 的**最新 SHA** 上全部通过，且至少 1 名非作者 code owner 批准（`reviewDecision=APPROVED`）
- [ ] 未越界：只改了 Issue「边界」内的内容
- [ ] `scripts/closeout.sh <pr#>` 五项全过（合并后由 dispatcher 跑）
- [ ] 新发现的坑已写进 [traps.md](traps.md)

判据来源：验收门禁**只用原生规则**（`required_approving_review_count: 1` + `require_code_owner_review` + `require_last_push_approval` + `dismiss_stale_reviews_on_push`）；**禁止**把验收做成自定义检查或 `/accept` 评论（见 [traps.md](traps.md) 陷阱 1）。
