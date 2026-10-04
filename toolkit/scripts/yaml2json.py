#!/usr/bin/env python3
# toolkit/scripts/yaml2json.py —— kit.yaml → JSON 的**严格子集**解析器（套件自带资产）
#
# 为什么存在（Issue #69 S-A 的设计要求）：
#   `kit.yaml` 是**出厂声明**（人写的、要可审计、可 diff），而套件的其余判据（install/eject/
#   统一不变量检查）都建立在 jq 之上。因此需要一个"声明 → JSON"的确定转换。
#
# 为什么不用 PyYAML / yq：NFR-01 轻量化 —— 零新增运行时依赖（本机实测 `import yaml` 不存在）。
# 为什么不用自制 awk（本项目已在 F12 吃过亏）：awk 版 YAML 解析只认固定几个键、按缩进猜测，
#   遇到多行 description / 引号内冒号会**静默误读**。本解析器的契约恰好相反：
#   **凡不在此处显式支持的构造，一律报错退出（退出码 2），绝不猜测。**
#
# 支持的子集（只此而已）：
#   · 注释：整行注释（`#` 起首）与标量后的行尾注释（`#` 前有空白，且不在引号内）
#   · 映射：`key: value` / `key:`（嵌套块，缩进确定层级）
#   · 序列：`- value` / `-`（嵌套块）/ `- key: value`（映射元素，后续同级键与 `-` 对齐）
#   · 标量：裸标量、`"…"`（支持 \" \\ \n \t \r \/ \uXXXX）、`'…'`（`''` 表示单引号）
#   · 块标量：`|` `|-` `|+` `>` `>-` `>+`
#   · 类型：`true` / `false` → JSON 布尔；`null` / `~` → null；整数/浮点 → 数字；其余 → 字符串
#
# 明确**不支持**（命中即报错，不静默降级）：
#   · 制表符缩进、多文档分隔符（`---` / `...`）、锚点与别名（`&` / `*`）、标签（`!!`）
#   · 流式集合（`{a: 1}` / `[1, 2]`）、合并键（`<<:`）、多行裸标量
#
# 用法：yaml2json.py KIT.yaml     → stdout 输出 JSON（缩进 2）
# 退出码：0 成功；2 解析失败（stderr 给出行号与原因）
import json
import re
import sys

INT_RE = re.compile(r"^-?[0-9]+$")
FLOAT_RE = re.compile(r"^-?([0-9]+\.[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$")
BLOCK_RE = re.compile(r"^([|>])([-+]?)$")
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "/": "/"}


class YamlError(Exception):
    pass


def _scan_unquoted(raw):
    """返回 [(文本, 是否在引号外)]，用于找"引号外的注释/块指示符"。"""
    out = []
    quote = None
    i = 0
    while i < len(raw):
        ch = raw[i]
        if quote:
            if quote == '"' and ch == "\\" and i + 1 < len(raw):
                out.append((raw[i:i + 2], True))
                i += 2
                continue
            if ch == quote and not (quote == "'" and i + 1 < len(raw) and raw[i + 1] == "'"):
                quote = None
            out.append((ch, False))
        else:
            if ch in "\"'":
                quote = ch
                out.append((ch, False))
            else:
                out.append((ch, True))
        i += 1
    return out


def _strip_comment(raw):
    scanned = _scan_unquoted(raw)
    for idx, (txt, outside) in enumerate(scanned):
        if outside and txt == "#" and idx > 0 and scanned[idx - 1][0][-1:] in (" ", "\t"):
            return "".join(t for t, _ in scanned[:idx]).rstrip()
    return "".join(t for t, _ in scanned).rstrip()


def _outside_mask(raw):
    """逐字符标记是否处于引号之外（用于定位注释/块指示符）。"""
    mask = []
    quote = None
    i = 0
    while i < len(raw):
        ch = raw[i]
        if quote:
            mask.append(False)
            if quote == '"' and ch == "\\" and i + 1 < len(raw):
                mask.append(False)
                i += 2
                continue
            if ch == quote and not (quote == "'" and i + 1 < len(raw) and raw[i + 1] == "'"):
                quote = None
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            mask.append(False)
            i += 1
            continue
        mask.append(True)
        i += 1
    return mask


def _block_indicator(content):
    """若 content 以引号外的块指示符结尾，返回 (key部分, 指示符)，否则 None。"""
    m = re.search(r"([|>])([-+]?)$", content)
    if not m:
        return None
    pos = m.start()
    mask = _outside_mask(content)
    if pos >= len(mask) or not mask[pos]:
        return None
    if pos > 0 and content[pos - 1] not in (" ", "\t", ":"):
        return None
    return content[:pos].rstrip(), m.group(1) + m.group(2)


def _scalar(tok):
    if len(tok) >= 2 and tok[0] == '"' and tok[-1] == '"':
        body = tok[1:-1]
        out = []
        i = 0
        while i < len(body):
            ch = body[i]
            if ch == "\\" and i + 1 < len(body):
                nxt = body[i + 1]
                if nxt == "u":
                    if i + 6 > len(body):
                        raise YamlError("\\u 转义不完整：%r" % tok)
                    try:
                        out.append(chr(int(body[i + 2:i + 6], 16)))
                    except ValueError:
                        raise YamlError("\\u 转义不合法：%r" % tok)
                    i += 6
                    continue
                if nxt not in ESCAPES:
                    raise YamlError("不支持的转义 \\%s（只支持 \\n \\t \\r \\\" \\\\ \\/ \\uXXXX）" % nxt)
                out.append(ESCAPES[nxt])
                i += 2
                continue
            out.append(ch)
            i += 1
        return "".join(out)
    if len(tok) >= 2 and tok[0] == "'" and tok[-1] == "'":
        return tok[1:-1].replace("''", "'")
    if tok == "" or tok in ("null", "~", "Null", "NULL"):
        return None
    if tok in ("true", "True", "TRUE"):
        return True
    if tok in ("false", "False", "FALSE"):
        return False
    if INT_RE.match(tok):
        return int(tok)
    if FLOAT_RE.match(tok):
        return float(tok)
    for bad, why in (
        ("&", "锚点（&name）"),
        ("*", "别名（*name）"),
        ("!!", "标签（!!type）"),
        ("{", "流式映射（{...}）"),
        ("[", "流式序列（[...]）"),
    ):
        if tok.startswith(bad):
            raise YamlError("不支持 %s（kit.yaml 只用本解析器支持的 YAML 子集）" % why)
    return tok


def _split_key(rest, lineno):
    """把 `key: value` 拆成 (key, value_str)；非映射返回 (None, None)。"""
    scanned = _scan_unquoted(rest)
    acc = 0
    for txt, outside in scanned:
        if outside and txt == ":":
            i = acc
            if i + 1 == len(rest) or rest[i + 1] in (" ", "\t"):
                key = rest[:i].strip()
                if not key:
                    raise YamlError("第 %d 行：键为空" % lineno)
                if len(key) >= 2 and key[0] == key[-1] and key[0] in "\"'":
                    key = _scalar(key)
                if key == "<<":
                    raise YamlError("第 %d 行：不支持合并键（<<:）" % lineno)
                return key, rest[i + 1:].strip()
        acc += len(txt)
    return None, None


class Parser(object):
    def __init__(self, text):
        self.items = []
        self._normalize(text.split("\n"))

    def _normalize(self, lines):
        i = 0
        while i < len(lines):
            line = lines[i]
            lineno = i + 1
            lead = line[: len(line) - len(line.lstrip(" \t"))]
            if "\t" in lead:
                raise YamlError("第 %d 行：缩进用了制表符（本解析器只支持空格缩进）" % lineno)
            stripped = line.lstrip(" ")
            indent = len(line) - len(stripped)
            if stripped.startswith("---") or stripped.startswith("..."):
                raise YamlError("第 %d 行：不支持多文档分隔符（--- / ...）" % lineno)
            if stripped.startswith("#"):
                i += 1
                continue
            content = _strip_comment(line).strip()
            if content == "":
                i += 1
                continue
            ind = _block_indicator(content)
            if ind is not None:
                head, style = ind
                body = []
                i += 1
                while i < len(lines):
                    l2 = lines[i]
                    if l2.strip() == "":
                        body.append("")
                        i += 1
                        continue
                    if "\t" in l2[: len(l2) - len(l2.lstrip(" \t"))]:
                        raise YamlError("第 %d 行：块标量内缩进用了制表符" % (i + 1))
                    if len(l2) - len(l2.lstrip(" ")) <= indent:
                        break
                    body.append(l2)
                    i += 1
                while body and body[-1] == "":
                    body.pop()
                base = min(len(b) - len(b.lstrip(" ")) for b in body) if body else 0
                body = [b[base:] if b.strip() else "" for b in body]
                if style[0] == ">":
                    text = " ".join(b.strip() for b in body).strip()
                else:
                    text = "\n".join(body)
                if style.endswith("-"):
                    text = text.rstrip("\n")
                else:
                    text = (text.rstrip("\n") + "\n") if text else text
                self.items.append((indent, head + " " + json.dumps(text), lineno))
                continue
            self.items.append((indent, content, lineno))
            i += 1
        if not self.items:
            raise YamlError("文件为空或只有注释")

    def parse(self):
        items = self.items
        value, pos = self._parse_block(items, 0, items[0][0])
        if pos != len(items):
            raise YamlError("第 %d 行：缩进层级无法归约（同级内容缩进不一致？）" % items[pos][2])
        return value

    @staticmethod
    def _is_seq(item):
        return item[1] == "-" or item[1].startswith("- ")

    def _parse_block(self, items, pos, indent):
        if self._is_seq(items[pos]):
            return self._parse_seq(items, pos, indent)
        mapping = {}
        while pos < len(items) and items[pos][0] == indent and not self._is_seq(items[pos]):
            key, rest = _split_key(items[pos][1], items[pos][2])
            if key is None:
                raise YamlError("第 %d 行：期望 `key: value`，实际为 %r" % (items[pos][2], items[pos][1]))
            if key in mapping:
                raise YamlError("第 %d 行：键 %r 重复" % (items[pos][2], key))
            if rest == "":
                pos += 1
                if pos < len(items) and items[pos][0] > indent:
                    mapping[key], pos = self._parse_block(items, pos, items[pos][0])
                else:
                    mapping[key] = None
            else:
                mapping[key] = _scalar(rest)
                pos += 1
        return mapping, pos

    def _parse_seq(self, items, pos, indent):
        seq = []
        while pos < len(items) and items[pos][0] == indent and self._is_seq(items[pos]):
            content = items[pos][1][1:].strip()
            lineno = items[pos][2]
            if content == "":
                pos += 1
                if pos < len(items) and items[pos][0] > indent:
                    item, pos = self._parse_block(items, pos, items[pos][0])
                else:
                    item = None
                seq.append(item)
                continue
            key, rest = _split_key(content, lineno)
            if key is None:
                seq.append(_scalar(content))
                pos += 1
                continue
            entry = {}
            cont_indent = None
            if pos + 1 < len(items) and items[pos + 1][0] > indent:
                cont_indent = items[pos + 1][0]
            if rest == "":
                pos += 1
                if pos < len(items) and items[pos][0] > indent:
                    entry[key], pos = self._parse_block(items, pos, items[pos][0])
                else:
                    entry[key] = None
            else:
                entry[key] = _scalar(rest)
                pos += 1
            if cont_indent is not None:
                while pos < len(items) and items[pos][0] == cont_indent and not self._is_seq(items[pos]):
                    k2, r2 = _split_key(items[pos][1], items[pos][2])
                    if k2 is None:
                        raise YamlError("第 %d 行：序列元素内出现非 `key: value` 内容" % items[pos][2])
                    if k2 in entry:
                        raise YamlError("第 %d 行：键 %r 重复" % (items[pos][2], k2))
                    if r2 == "":
                        pos += 1
                        if pos < len(items) and items[pos][0] > cont_indent:
                            entry[k2], pos = self._parse_block(items, pos, items[pos][0])
                        else:
                            entry[k2] = None
                    else:
                        entry[k2] = _scalar(r2)
                        pos += 1
            seq.append(entry)
        return seq, pos


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("用法：yaml2json.py <file.yaml>\n")
        return 2
    try:
        with open(argv[1], "r") as fh:
            text = fh.read()
        data = Parser(text).parse()
    except YamlError as exc:
        sys.stderr.write("[FAIL] kit.yaml 解析失败：%s\n" % exc)
        return 2
    except (IOError, OSError) as exc:
        sys.stderr.write("[FAIL] 无法读取 %s：%s\n" % (argv[1], exc))
        return 2
    sys.stdout.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
