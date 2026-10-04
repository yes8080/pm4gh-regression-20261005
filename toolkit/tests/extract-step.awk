#!/usr/bin/env awk -f
# extract-step.awk —— 从 workflow YAML 里抽出某个 step 的 run 脚本正文
# 用法：awk -v want="步骤名" -f extract-step.awk file.yml
# 依据缩进（YAML block scalar）：`run: |` 之后缩进更深的所有行都属于脚本正文。
BEGIN { found = 0; run = 0; ind = 0 }
!found && $0 ~ ("^[ ]+- name: " want "[ ]*$") { found = 1; next }
found == 1 && $0 ~ "^[ ]+run: \\|" { run = 1; ind = match($0, /[^ ]/) - 1; next }
run == 1 {
  if ($0 ~ /^[ ]*$/) { print ""; next }
  cur = match($0, /[^ ]/) - 1
  if (cur <= ind) { exit }
  print substr($0, ind + 3)
}
