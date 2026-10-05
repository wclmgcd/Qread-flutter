#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/fonts/ 下的内置中文字体。

全量中文字体（Noto Sans SC / Noto Serif SC 各 17~25 MB，霞鹜文楷 24 MB）直接
打包会让 APK 多出 90 MB，所以这里做两步压缩：

  1. 子集化：只保留 GB2312 全集（7445 字）+ ASCII + 常用标点/符号/假名，
     约 9800 个字符 —— 覆盖 99.99% 的现代简体中文正文。
  2. 实例化：Noto 的两个字族是可变字体（wght 100~900），按 400 / 700
     各实例化一份静态字体。静态字体不依赖 Flutter 的 fontVariations 支持，
     最稳；「粗细」开关改 FontWeight 就能命中真粗体。

结果：6 个文件共约 19.5 MB。

用法：
    pip install fonttools brotli
    python tool/subset_fonts.py            # 下载 + 裁剪（首次较慢）
    python tool/subset_fonts.py --no-download   # 只用已有源字体

源字体缓存在 tool/.fonts-src/（已 gitignore），不会进仓库。
字体授权均为 SIL OFL-1.1，允许随应用分发。
"""
from __future__ import annotations

import argparse
import os
import sys
import urllib.request

from fontTools.ttLib import TTFont
from fontTools.subset import Options, Subsetter
from fontTools.varLib.instancer import instantiateVariableFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO, "assets", "fonts")
SRC_DIR = os.path.join(REPO, "tool", ".fonts-src")

# 名字 -> (下载地址, 授权)
SOURCES = {
    "NotoSansSC.ttf": (
        "https://github.com/google/fonts/raw/main/ofl/notosanssc/"
        "NotoSansSC%5Bwght%5D.ttf",
        "Noto Sans SC, OFL-1.1",
    ),
    "NotoSerifSC.ttf": (
        "https://github.com/google/fonts/raw/main/ofl/notoserifsc/"
        "NotoSerifSC%5Bwght%5D.ttf",
        "Noto Serif SC, OFL-1.1",
    ),
    "Yozai-Regular.ttf": (
        "https://github.com/lxgw/yozai-font/releases/download/v0.868/"
        "Yozai-Regular.ttf",
        "悠哉字体 Yozai, OFL-1.1",
    ),
    "Yozai-Medium.ttf": (
        "https://github.com/lxgw/yozai-font/releases/download/v0.868/"
        "Yozai-Medium.ttf",
        "悠哉字体 Yozai, OFL-1.1",
    ),
}

# 输出文件 -> (源文件, 可变字体轴取值或 None, family, subfamily, weight)
TARGETS = {
    "ReaderSans-Regular.ttf": ("NotoSansSC.ttf", 400, "ReaderSans", "Regular", 400),
    "ReaderSans-Bold.ttf": ("NotoSansSC.ttf", 700, "ReaderSans", "Bold", 700),
    "ReaderSerif-Regular.ttf": (
        "NotoSerifSC.ttf", 400, "ReaderSerif", "Regular", 400),
    "ReaderSerif-Bold.ttf": ("NotoSerifSC.ttf", 700, "ReaderSerif", "Bold", 700),
    "ReaderRound-Regular.ttf": (
        "Yozai-Regular.ttf", None, "ReaderRound", "Regular", 400),
    # 悠哉字体没有 Bold，用 Medium 顶替加粗档（比合成加粗自然）
    "ReaderRound-Bold.ttf": ("Yozai-Medium.ttf", None, "ReaderRound", "Bold", 700),
}

# GB2312 之外、网络小说里偶尔会出现的字
EXTRA_CHARS = (
    "囧兲氼烎砳嘦嫑巭恏兙兛兝兞兡兣唝唞嗧嘢囍"
    "冇乜嘅咁睇啲嘢咗噉喺哋嗰咩咯噢喔诶嘿嗯呐喽呗嘞嘛"
)

SYMBOL_RANGES = [
    (0x00A0, 0x00FF),  # 拉丁补充
    (0x2000, 0x206F),  # 常用标点（省略号、破折号）
    (0x2070, 0x209F),  # 上下标
    (0x20A0, 0x20BF),  # 货币符号
    (0x2100, 0x214F),  # 字母式符号（℃ ℉ №）
    (0x2190, 0x21FF),  # 箭头
    (0x2200, 0x22FF),  # 数学运算符
    (0x2460, 0x24FF),  # 带圈数字
    (0x2500, 0x257F),  # 制表符
    (0x25A0, 0x25FF),  # 几何图形（■ □ ● ○ ★ ☆）
    (0x2600, 0x26FF),  # 杂项符号
    (0x2700, 0x27BF),  # 装饰符号（✓ ✗）
    (0x3000, 0x303F),  # CJK 标点（、。「」『』）
    (0x3040, 0x30FF),  # 平假名 / 片假名
    (0x3100, 0x312F),  # 注音符号
    (0x31C0, 0x31EF),  # CJK 笔画
    (0x3200, 0x32FF),  # 带圈 CJK
    (0x3300, 0x33FF),  # CJK 兼容（㍿）
    (0xFE10, 0xFE1F),  # 竖排标点
    (0xFE30, 0xFE4F),  # CJK 兼容标点
    (0xFE50, 0xFE6F),  # 小写变体
    (0xFF00, 0xFFEF),  # 全角字符
]

MAC = (1, 0, 0)
WIN = (3, 1, 0x409)


def build_charset() -> str:
    chars = {chr(c) for c in range(0x20, 0x7F)}
    for b1 in range(0xA1, 0xF8):
        for b2 in range(0xA1, 0xFF):
            try:
                chars.add(bytes([b1, b2]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    for start, end in SYMBOL_RANGES:
        chars.update(chr(c) for c in range(start, end + 1))
    chars.update(EXTRA_CHARS)
    return "".join(sorted(chars))


def download(name: str) -> str:
    dst = os.path.join(SRC_DIR, name)
    if os.path.exists(dst) and os.path.getsize(dst) > 1_000_000:
        print("  cached:", name)
        return dst
    url = SOURCES[name][0]
    print("  downloading:", name)
    os.makedirs(SRC_DIR, exist_ok=True)
    tmp = dst + ".part"
    with urllib.request.urlopen(url, timeout=120) as resp, open(tmp, "wb") as fh:
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            fh.write(chunk)
    os.replace(tmp, dst)
    return dst


def subset(src: str, dst: str, text: str) -> None:
    opts = Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.name_legacy = True
    opts.notdef_outline = True
    opts.recalc_bounds = True
    opts.drop_tables = ["DSIG"]
    opts.passthrough_tables = False

    font = TTFont(src)
    sub = Subsetter(options=opts)
    sub.populate(text=text)
    sub.subset(font)
    font.save(dst)
    font.close()


def instance(src: str, dst: str, wght: float) -> None:
    font = TTFont(src)
    instantiateVariableFont(
        font, {"wght": wght}, inplace=True, updateFontNames=False
    )
    font.save(dst)
    font.close()


def fix_names(path: str, family: str, subfamily: str, weight: int) -> None:
    """Flutter 只看 pubspec 的 family，但内部名正确可以避免引擎配对歧义。"""
    font = TTFont(path)
    nt = font["name"]
    full = family if subfamily == "Regular" else "%s %s" % (family, subfamily)
    ps = full.replace(" ", "")

    def put(name_id: int, value: str) -> None:
        for platform, enc, lang in (MAC, WIN):
            nt.setName(value, name_id, platform, enc, lang)

    put(1, family)
    put(2, subfamily)
    put(3, "%s;v1.0" % ps)
    put(4, full)
    put(6, ps)
    put(16, family)
    put(17, subfamily)
    font["OS/2"].usWeightClass = weight
    font.save(path)
    font.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--no-download", action="store_true", help="只使用已缓存的源字体"
    )
    args = parser.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    text = build_charset()
    print("charset: %d chars" % len(text))

    if not args.no_download:
        print("resolving sources:")
        for name in SOURCES:
            download(name)

    total = 0
    for out_name, (src_name, wght, family, subfamily, weight) in TARGETS.items():
        src = os.path.join(SRC_DIR, src_name)
        if not os.path.exists(src):
            print("!! missing source: %s" % src)
            return 1
        out = os.path.join(OUT_DIR, out_name)

        if wght is None:
            subset(src, out, text)
        else:
            tmp = out + ".subset.tmp"
            subset(src, tmp, text)
            instance(tmp, out, wght)
            os.remove(tmp)

        fix_names(out, family, subfamily, weight)
        total += os.path.getsize(out)
        print("  %-24s %6.2f MB" % (out_name, os.path.getsize(out) / 1048576))

    print("total: %.2f MB" % (total / 1048576))
    return 0


if __name__ == "__main__":
    sys.exit(main())
