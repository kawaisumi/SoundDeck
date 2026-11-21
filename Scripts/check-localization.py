#!/usr/bin/env python3
"""檢查介面文字有沒有漏翻。

掃描 Sources/ 裡所有含中文的字串常值（跳過註解、記錄、測試用的除錯輸出），
列出 Resources/en.lproj/Localizable.strings 裡還沒有英文翻譯的字串。

用法：python3 Scripts/check-localization.py          列出漏翻的字串
      python3 Scripts/check-localization.py --keys   列出所有需要翻譯的字串
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STRINGS = ROOT / "Resources" / "en.lproj" / "Localizable.strings"

LITERAL = re.compile(r'(?<!#)"((?:[^"\\\n]|\\.)*)"')
CJK = re.compile(r"[一-鿿]")
# 這些行裡的中文不會顯示在介面上。
# 行尾加上「// 不翻譯」可以明確標示某一行不需要翻譯（例如依語言整段切換的內容、記錄訊息的接續行）。
SKIP_LINE = re.compile(r"Log\.|logger\.|precondition\(|name: \"Tonefleur|print\(|^\s*\"\||current \? \"\||// 不翻譯")


def source_keys():
    keys, interpolated = {}, []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        in_block = False
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            # 多行字串（例如給 AI 的整段範本）依語言整段切換，不逐句翻譯。
            if stripped.count('"""') % 2 == 1:
                in_block = not in_block
                continue
            if in_block or stripped.startswith("//") or SKIP_LINE.search(line):
                continue
            for literal in LITERAL.findall(line):
                if not CJK.search(literal):
                    continue
                where = f"{path.relative_to(ROOT)}:{number}"
                if "\\(" in literal:
                    interpolated.append((where, literal))
                else:
                    keys.setdefault(literal, where)
    return keys, interpolated


def translated_keys():
    if not STRINGS.exists():
        return set()
    text = STRINGS.read_text(encoding="utf-8")
    return set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.MULTILINE))


def main():
    keys, interpolated = source_keys()
    if "--keys" in sys.argv:
        for key in keys:
            print(key)
        return 0

    done = translated_keys()
    missing = [(where, key) for key, where in keys.items() if key not in done]
    for where, key in missing:
        print(f"漏翻  {where}  \"{key}\"")
    for where, literal in interpolated:
        print(f"無法翻譯（字串裡有 \\(…)，請改用 L(…, 參數)）  {where}  \"{literal}\"")
    unused = sorted(done - set(keys))
    for key in unused:
        print(f"沒用到的翻譯  \"{key}\"")
    if not missing and not interpolated:
        print(f"全部 {len(keys)} 個字串都有英文翻譯。")
    return 1 if missing or interpolated else 0


if __name__ == "__main__":
    sys.exit(main())
