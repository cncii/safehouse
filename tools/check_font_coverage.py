#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_font_coverage.py — 中文字体缺字检测（风格契约 S6 门禁）。

背景：S6 是「一票否决项」——字体不含 license 不能用；反过来，字体缺字会让界面
出现豆腐块 `□`，而 **全项目没有任何自动化门禁能查出来**（check_assets.py 只管 PNG）。
本脚本补的就是这个洞：拿 strings.csv 里真实用到的每一个字，去字体里查有没有字形。

为什么不依赖 fontTools：本工程其他工具零第三方依赖，且 fontTools 默认未安装。
这里直接解析 sfnt 的 `cmap` 表（format 4 / format 12），只回答一个问题——
「这个码位在字体里有没有字形」。

用法：
  python tools/check_font_coverage.py \\
      --csv data/locale/strings.csv \\
      --font assets/fonts/ark-pixel-12px-monospaced-zh_hans.ttf \\
      --font assets/fonts/ark-pixel-12px-monospaced-zh_tw.ttf

  # 只看汇总，不逐列展开
  python tools/check_font_coverage.py --csv data/locale/strings.csv --font X.ttf --quiet

退出码：0 = 全列全字覆盖；1 = 存在缺字（可直接进 CI）。
"""

import argparse
import csv
import struct
import sys
from pathlib import Path

# 检测范围：CJK 统一表意文字 + 扩展A + 兼容表意 + 中文标点/全角符号
CJK_RANGES = (
    (0x4E00, 0x9FFF),    # CJK 统一表意文字
    (0x3400, 0x4DBF),    # 扩展 A
    (0xF900, 0xFAFF),    # 兼容表意文字
    (0x3000, 0x303F),    # 中文标点
    (0xFF00, 0xFFEF),    # 全角字符
)


def is_cjk(ch):
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in CJK_RANGES)


# ── sfnt / cmap 解析 ──────────────────────────────────────────────────────

def _u16(b, o):
    return struct.unpack(">H", b[o:o + 2])[0]


def _i16(b, o):
    return struct.unpack(">h", b[o:o + 2])[0]


def _u32(b, o):
    return struct.unpack(">I", b[o:o + 4])[0]


def _table_dir(data):
    """返回 {tag: (offset, length)}。"""
    num = _u16(data, 4)
    tables = {}
    for i in range(num):
        rec = 12 + i * 16
        tag = data[rec:rec + 4].decode("latin-1")
        tables[tag] = (_u32(data, rec + 8), _u32(data, rec + 12))
    return tables


def _cmap_subtables(data, cmap_off):
    """返回 [(platformID, encodingID, subtable_offset)]。"""
    n = _u16(data, cmap_off + 2)
    out = []
    for i in range(n):
        rec = cmap_off + 4 + i * 8
        pid, eid = _u16(data, rec), _u16(data, rec + 2)
        sub = _u32(data, rec + 4)
        out.append((pid, eid, cmap_off + sub))
    return out


def _fmt4_segments(data, off):
    seg_x2 = _u16(data, off + 6)
    seg = seg_x2 // 2
    end_base = off + 14
    start_base = end_base + seg_x2 + 2
    delta_base = start_base + seg_x2
    range_base = delta_base + seg_x2
    segs = []
    for i in range(seg):
        end = _u16(data, end_base + i * 2)
        start = _u16(data, start_base + i * 2)
        delta = _i16(data, delta_base + i * 2)
        ro_pos = range_base + i * 2
        ro = _u16(data, ro_pos)
        if start == 0xFFFF and end == 0xFFFF:
            continue
        segs.append((start, end, delta, ro_pos, ro))
    return segs


def _fmt4_has(data, segs, cp):
    for start, end, delta, ro_pos, ro in segs:
        if not (start <= cp <= end):
            continue
        if ro == 0:
            return ((cp + delta) & 0xFFFF) != 0
        idx = ro_pos + ro + 2 * (cp - start)
        if idx + 1 >= len(data):
            return False
        gid = _u16(data, idx)
        if gid == 0:
            return False
        return ((gid + delta) & 0xFFFF) != 0
    return False


def _fmt12_groups(data, off):
    n = _u32(data, off + 12)
    groups = []
    for i in range(n):
        rec = off + 16 + i * 12
        start, end, sgid = _u32(data, rec), _u32(data, rec + 4), _u32(data, rec + 8)
        groups.append((start, end, sgid))
    return groups


def _fmt12_has(groups, cp):
    for start, end, sgid in groups:
        if start <= cp <= end:
            return (sgid + (cp - start)) != 0
    return False


def load_codepoints(path):
    """读取字体 cmap，返回一个判定函数 has(cp) -> bool。"""
    data = Path(path).read_bytes()
    if data[:4] not in (b"\x00\x01\x00\x00", b"true", b"OTTO"):
        raise SystemExit("不是可识别的 sfnt 字体文件: %s" % path)
    tables = _table_dir(data)
    if "cmap" not in tables:
        raise SystemExit("字体没有 cmap 表: %s" % path)

    fmt4, fmt12 = [], []
    for pid, eid, off in _cmap_subtables(data, tables["cmap"][0]):
        # 只认 Unicode 映射：platform 0（Unicode）或 platform 3 encoding 1/10
        if not (pid == 0 or (pid == 3 and eid in (1, 10))):
            continue
        fmt = _u16(data, off)
        if fmt == 4:
            fmt4.append(_fmt4_segments(data, off))
        elif fmt == 12:
            fmt12.append(_fmt12_groups(data, off))

    if not fmt4 and not fmt12:
        raise SystemExit("字体没有可用的 Unicode cmap 子表（format 4/12）: %s" % path)

    def has(cp):
        for segs in fmt4:
            if _fmt4_has(data, segs, cp):
                return True
        for groups in fmt12:
            if _fmt12_has(groups, cp):
                return True
        return False

    return has


# ── 语料采集 ──────────────────────────────────────────────────────────────

def gb2312_level1():
    """GB2312 一级汉字（3755 字，区 16–55）。用途：评估字体的「未来加文案」风险——
    只测当前 strings.csv 会低估缺字，因为文案会持续增长。"""
    out = []
    for hi in range(0xB0, 0xD8):
        for lo in range(0xA1, 0xFE):
            try:
                ch = bytes([hi, lo]).decode("gb2312")
            except UnicodeDecodeError:
                continue
            if len(ch) == 1:
                out.append(ch)
    return out


def load_csv_chars(csv_path):
    """按列收集 CJK 字符：{'zh_CN': set(...), 'zh_TW': set(...), ...}"""
    raw = Path(csv_path).read_text(encoding="utf-8-sig")
    rows = list(csv.reader(raw.splitlines()))
    if not rows:
        raise SystemExit("CSV 为空: %s" % csv_path)
    header = [h.strip() for h in rows[0]]
    cols = {}
    for ci, name in enumerate(header):
        if name.upper() == "KEY":
            continue  # KEY 是内部标识，玩家看不见，不参与字体覆盖判定
        s = set()
        for r in rows[1:]:
            if ci < len(r):
                s.update(ch for ch in r[ci] if is_cjk(ch))
        cols[name] = s
    meta = {"rows": len(rows) - 1, "header": header}
    return cols, meta


def main():
    ap = argparse.ArgumentParser(description="中文字体缺字检测（S6 门禁）")
    ap.add_argument("--csv", help="本地化 CSV（表头须含 zh_CN / zh_TW 等列）")
    ap.add_argument("--gb2312-l1", action="store_true",
                    help="改用 GB2312 一级汉字（3755 字）作语料，评估字体自身字表广度")
    ap.add_argument("--font", action="append", required=True,
                    help="待检字体路径，可重复传多个")
    ap.add_argument("--quiet", action="store_true", help="只输出汇总行")
    args = ap.parse_args()
    if not args.csv and not args.gb2312_l1:
        ap.error("需要 --csv 或 --gb2312-l1 之一")

    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    if args.csv:
        cols, meta = load_csv_chars(args.csv)
        print("语料: %s  (%d 行, 列: %s)" % (args.csv, meta["rows"], " / ".join(meta["header"])))
    else:
        l1 = gb2312_level1()
        cols, meta = {"gb2312-l1": set(l1)}, {"rows": len(l1), "header": ["gb2312-l1"]}
        print("语料: GB2312 一级汉字 %d 字（未来加文案的风险面）" % len(l1))
    total = set().union(*cols.values()) if cols else set()
    print("唯一 CJK 字符: %d" % len(total))
    for name, s in cols.items():
        print("  %-8s %d 字" % (name, len(s)))

    failed = False
    for font in args.font:
        has = load_codepoints(font)
        missing_all = sorted(c for c in total if not has(ord(c)))
        print("\n── %s" % Path(font).name)
        print("   覆盖 %d/%d 字 (%.1f%%)，缺 %d"
              % (len(total) - len(missing_all), len(total),
                 100.0 * (len(total) - len(missing_all)) / max(len(total), 1),
                 len(missing_all)))
        if not args.quiet:
            for name, s in cols.items():
                miss = sorted(c for c in s if not has(ord(c)))
                flag = "OK " if not miss else "缺 %d" % len(miss)
                print("   [%s] %-8s %s%s"
                      % (flag, name, "".join(miss[:40]),
                         " …" if len(miss) > 40 else ""))
        if missing_all:
            failed = True
            print("   缺失字符: %s" % "".join(missing_all))

    print("\n结论: %s" % ("存在缺字 —— S6 不通过" if failed else "全部覆盖 —— S6 通过"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
