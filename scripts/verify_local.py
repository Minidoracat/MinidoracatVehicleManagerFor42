# -*- coding: utf-8 -*-
"""VehicleManager 專屬的靜態檢查：scripts/verify_mod.py 第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。

帳本分片容量 — 單一 GOS 系統存檔共用 10 MiB SliceBuffer；每片最壞大小 ≤ 8 MiB、全伺服器 GOS 系統預算 ≤ 110
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped = [], [], []

# 豁免清單與 verify_mod.py 共用：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
IGNORE_PATTERNS = []
_ign = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_ignore.txt")
if os.path.isfile(_ign):
    with open(_ign, encoding="utf-8") as _fh:
        for _line in _fh:
            _line = _line.strip()
            if _line and not _line.startswith("#"):
                IGNORE_PATTERNS.append(_line)


def ok(label):
    passed.append(label)
    print(f"  PASS  {label}")


def fail(label, details=None):
    if not details:  # 說失敗卻沒附細節（例：子程序結束碼非零但沒輸出）也是失敗；空清單走下面會記成 PASS
        failed.append(label)
        print(f"  FAIL  {label}")
        return
    kept = [d for d in details if not any(p in d for p in IGNORE_PATTERNS)]
    waived = [d for d in details if any(p in d for p in IGNORE_PATTERNS)]
    for d in waived:
        print(f"  WAIVE {label}: {d}（verify_ignore.txt 豁免）")
    if not kept:
        if waived:
            ok(f"{label}（{len(waived)} 筆豁免）")
        else:
            ok(label)
        return
    failed.append(label)
    print(f"  FAIL  {label}")
    for d in kept:
        print(f"        {d}")


def find_media():
    hits = []
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            p = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(p):
                continue
            for inner in os.listdir(p):
                media = os.path.join(p, inner, "42", "media")
                if os.path.isdir(media):
                    hits.append(media)
    return hits


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

# ---- 帳本分片容量 ----
# 從舊 verify_mod.py 第 10 項（沙盒選項翻譯配對）的迴圈搬來，跑的條件照舊：有 sandbox-options.txt 與 CH/Sandbox.json
# （缺 CH/Sandbox.json 由 verify_mod.py 的沙盒選項翻譯配對報 FAIL）。
for m in MEDIA_DIRS:
    sb = os.path.join(m, "sandbox-options.txt")
    if not os.path.isfile(sb):
        continue
    with open(sb, encoding="utf-8") as fh:
        txt = fh.read()
    ch = os.path.join(m, "lua", "shared", "Translate", "CH", "Sandbox.json")
    if not os.path.isfile(ch):
        continue
    # 帳本分片容量：單一 GOS 系統存檔共用 10 MiB SliceBuffer，超過會在已截斷檔案後拋錯（SGlobalObjectSystem.java:273-298）。
    # 每片最壞大小＝紀錄上限×(固定欄位 ~900 B＋成員上限×80 B)＋小項目上限×150 B，必須 ≤ 8 MiB；
    # 開新分片的全伺服器 GOS 系統預算 ≤ 110（客戶端以有號 byte 讀系統數，>127 全部 MOD 的客戶端 GOS 會壞）
    mem = re.search(r"option\s+MinidoracatVehicleManager\.MaxMembersPerVehicle\s*\{[^}]*?max\s*=\s*(\d+)", txt)
    own = os.path.join(m, "lua", "server", "MinidoracatVehicleManager_OwnershipSystem.lua")
    lim = None
    if os.path.isfile(own):
        with open(own, encoding="utf-8") as fh:
            lim = re.search(r"O\.SHARD_LIMITS\s*=\s*\{\s*records\s*=\s*(\d+),\s*entries\s*=\s*(\d+),\s*shards\s*=\s*(\d+),\s*systemBudget\s*=\s*(\d+)", fh.read())
    if mem and lim:
        records, entries, shards, budget = (int(x) for x in lim.groups())
        worst = records * (900 + int(mem.group(1)) * 80) + entries * 150
        bad = []
        if worst > 8 * 1024 * 1024:
            bad.append(f"每片最壞 {worst} B 超過 8 MiB")
        if budget > 110:
            bad.append(f"全伺服器 GOS 系統預算 {budget} 太接近客戶端有號 byte 上限 127（CGlobalObjects.java:105）")
        fail("帳本分片容量", bad) if bad else ok(f"帳本分片容量（每片最壞 {worst // 1024} KiB，本 MOD 最多 {shards} 片，全伺服器系統預算 {budget}）")
    else:
        fail("帳本分片容量", ["找不到 MaxMembersPerVehicle 選項或 O.SHARD_LIMITS 常數"])

sys.exit(1 if failed else 0)
