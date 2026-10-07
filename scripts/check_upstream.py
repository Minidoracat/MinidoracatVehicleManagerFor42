#!/usr/bin/env python3
"""查 upstream.json 登記的第三方 Workshop MOD（本 MOD 的指令防火牆、adapter、玩家端防護依賴它們）是否在我們核對過之後又更新了。

    python scripts/check_upstream.py                    # 時間戳＋（有本機副本時）檔案比對；有更新 exit 1
    python scripts/check_upstream.py --ack 3409472393   # 重核完規則：記下時間戳與全檔 hash 清單，watch_files 另存本機快照
    python scripts/check_upstream.py --ack all
    python scripts/check_upstream.py --report out.json  # 給 GitHub Action 的結構化輸出
    python scripts/check_upstream.py --source DIR       # workshop content 根（其下為 <wid>/…）；預設 PZ_WORKSHOP_DIR 或本機 Steam 訂閱目錄

三層資訊：
  1. 時間戳（Steam ISteamRemoteStorage/GetPublishedFileDetails，公開 API）——永遠有，是開 issue 的唯一觸發
  2. 全 MOD 檔案清單差異（與 upstream/<wid>.files.json 的 sha256 清單比）——有來源目錄才有
  3. 哪些 watch_files 變了（同樣比 hash）——有來源目錄才有
比對只是附加資訊；抓不到來源也照樣回報「有更新」。

公開 repo：不 commit 第三方檔案內容，只留 hash 清單。--ack 另把 watch_files 複製到 temp/upstream-snapshots/<wid>/
（gitignored，只在本機）；之後本機副本更新時，命令列輸出會附上 watch_files 的 unified diff。CI 沒有快照、也不需要。
--ack 前會比對本機 Steam 的 appworkshop_108600.acf：本機副本不是 Steam 最新版就不 ack 該上游（先讓 Steam 更新）。
"""
import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / "upstream.json"
STATE = ROOT / "upstream"
SNAPSHOTS = ROOT / "temp" / "upstream-snapshots"
API = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
DEFAULT_SOURCES = [
    os.environ.get("PZ_WORKSHOP_DIR", ""),
    "D:/SteamLibrary/steamapps/workshop/content/108600",
]
DIFF_MAX_LINES = 400


def fetch_details(wids):
    form = {"itemcount": str(len(wids))}
    for i, wid in enumerate(wids):
        form[f"publishedfileids[{i}]"] = str(wid)
    req = urllib.request.Request(API, data=urllib.parse.urlencode(form).encode(), method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.load(resp)
    return {str(d["publishedfileid"]): d for d in payload["response"]["publishedfiledetails"]}


def fmt(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(ts)) + " UTC" if ts else "（未核對）"


def find_source(explicit):
    for cand in ([explicit] if explicit else DEFAULT_SOURCES):
        if cand and Path(cand).is_dir():
            return Path(cand)
    return None


def hash_tree(root: Path):
    out = {}
    for p in sorted(root.rglob("*")):
        if p.is_file():
            out[p.relative_to(root).as_posix()] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def local_time_updated(src_dir: Path, wid):
    """本機 Steam 記錄的該 wid 版本時間（<steamapps>/workshop/appworkshop_108600.acf）；找不到回 None。"""
    acf = src_dir.parent.parent / "appworkshop_108600.acf"
    if not acf.is_file():
        return None
    m = re.search(rf'"{wid}"\s*\{{[^}}]*?"timeupdated"\s*"(\d+)"', acf.read_text(encoding="utf-8", errors="replace"))
    return int(m.group(1)) if m else None


def compare(u, src_dir: Path):
    """回傳 {status, added, removed, modified, watch_changed}；watch_changed＝{relpath: added|removed|modified}。"""
    wid = str(u["wid"])
    cur_root = src_dir / wid
    if not cur_root.is_dir():
        return {"status": "no_source"}
    baseline_file = STATE / f"{wid}.files.json"
    if not baseline_file.exists():
        return {"status": "no_baseline", "hint": f"先跑 --ack {wid} 建立基線"}
    old = json.loads(baseline_file.read_text(encoding="utf-8"))
    new = hash_tree(cur_root)
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    modified = sorted(k for k in set(old) & set(new) if old[k] != new[k])
    watch_changed = {}
    for rel in u["watch_files"]:
        if rel not in new:
            watch_changed[rel] = "removed"
        elif rel not in old:
            watch_changed[rel] = "added"
        elif old[rel] != new[rel]:
            watch_changed[rel] = "modified"
    return {"status": "ok", "added": added, "removed": removed, "modified": modified, "watch_changed": watch_changed}


def local_diff(wid, rel, cur: Path):
    """本機快照與目前副本的 unified diff（只給命令列看）；沒有快照回 None。"""
    snap = SNAPSHOTS / wid / rel
    if not snap.is_file() or not cur.is_file():
        return None
    read = lambda p: p.read_text(encoding="utf-8", errors="replace").splitlines()
    lines = list(difflib.unified_diff(read(snap), read(cur), f"acked/{rel}", f"steam/{rel}", lineterm=""))
    if len(lines) > DIFF_MAX_LINES:
        lines = lines[:DIFF_MAX_LINES] + [f"… 截斷（共 {len(lines)} 行）"]
    return "\n".join(lines)


def ack(u, src_dir, now):
    wid = str(u["wid"])
    cur_root = src_dir / wid if src_dir else None
    if not cur_root or not cur_root.is_dir():
        print(f"  {wid}: 找不到本機副本，不 ack（需要本機副本才能建 hash 基線）")
        return
    local = local_time_updated(src_dir, wid)
    if local is not None and local != now:
        print(f"  {wid}: 本機副本 {fmt(local)} ≠ Steam {fmt(now)}，先讓 Steam 更新再 ack")
        return
    missing = [rel for rel in u["watch_files"] if not (cur_root / rel).is_file()]
    if missing:
        print(f"  {wid}: watch_files 找不到 {missing}，修正 upstream.json 後再 ack")
        return
    files = hash_tree(cur_root)
    STATE.mkdir(exist_ok=True)
    (STATE / f"{wid}.files.json").write_text(json.dumps(files, indent=1) + "\n", encoding="utf-8")
    snap_root = SNAPSHOTS / wid
    if snap_root.exists():
        shutil.rmtree(snap_root)
    for rel in u["watch_files"]:
        dst = snap_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(cur_root / rel, dst)
    u["acked_time_updated"] = now
    print(f"  {wid}: 時間戳 {fmt(now)}、{len(files)} 檔 hash、{len(u['watch_files'])} 個本機快照")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ack", metavar="WID|all")
    ap.add_argument("--report", metavar="FILE")
    ap.add_argument("--source", metavar="DIR", help="workshop content 根目錄（其下為 <wid>/）")
    args = ap.parse_args()

    data = json.loads(UPSTREAM.read_text(encoding="utf-8"))
    ups = data["upstreams"]
    details = fetch_details([u["wid"] for u in ups])
    src_dir = find_source(args.source)

    if args.ack:
        for u in ups:
            if args.ack not in ("all", str(u["wid"])):
                continue
            d = details.get(str(u["wid"]))
            if not d or d.get("result") != 1:
                print(f"  {u['wid']}: Steam 回 result={d.get('result') if d else None}，不 ack")
                continue
            ack(u, src_dir, int(d["time_updated"]))
        UPSTREAM.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return 0

    changed = []
    for u in ups:
        d = details.get(str(u["wid"]))
        if not d or d.get("result") != 1:
            changed.append({**u, "status": "unavailable", "steam_result": d.get("result") if d else None})
            continue
        now = int(d["time_updated"])
        if now > int(u.get("acked_time_updated", 0)):
            changed.append({**u, "status": "updated", "steam_time_updated": now, "steam_title": d.get("title"),
                            "compare": compare(u, src_dir) if src_dir else {"status": "no_source"}})

    if args.report:
        Path(args.report).write_text(json.dumps(changed, ensure_ascii=False, indent=2), encoding="utf-8")

    if not changed:
        print(f"OK — {len(ups)} 個上游都沒有新更新")
        return 0
    for c in changed:
        if c["status"] == "unavailable":
            print(f"!! {c['name']} ({c['wid']}) Steam 回 result={c['steam_result']}，可能已下架")
            continue
        print(f"!! {c['name']} ({c['wid']}) 上游更新 {fmt(c['steam_time_updated'])}（核對過的是 {fmt(c.get('acked_time_updated'))}）")
        print("   受影響：" + "、".join(c["affects"]))
        cmp_ = c["compare"]
        if cmp_["status"] != "ok":
            print(f"   檔案比對：{cmp_['status']} {cmp_.get('hint', '')}")
            continue
        print(f"   檔案差異：+{len(cmp_['added'])} −{len(cmp_['removed'])} ~{len(cmp_['modified'])}")
        for k in ("added", "removed", "modified"):
            for rel in cmp_[k]:
                print(f"     {k[0].upper()} {rel}")
        for rel, kind in cmp_["watch_changed"].items():
            print(f"   watch {kind}: {rel}")
            diff = local_diff(str(c["wid"]), rel, src_dir / str(c["wid"]) / rel)
            if diff:
                print(diff)
        if not (cmp_["added"] or cmp_["removed"] or cmp_["modified"]):
            print("   檔案零差異（作者重傳同內容），可直接 --ack")
    return 1


if __name__ == "__main__":
    sys.exit(main())
