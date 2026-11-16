# -*- coding: utf-8 -*-
"""卡片绑定解析器：UIA 卡片 ↔ 主进程权威配对表（object_id ↔ encfilekey）。

数据源：
  work/uia_cards.json     UIA 枚举卡片
  work/main_pairs.json    主进程 object_id↔20302 键配对（main-pair.py）
  work/mem_model2.json    renderer 结构化记录（序号/时长/点赞/nonce/邻近 URL）

回表优先级：
  1. oid 主键直连；
  2. oid 缺失时按 encfilekey / m 跨进程归并（ek/m 按流会话轮换，仅兜底）；
  3. 对齐先比网格序号(index)，再比时长（必须精确相等），点赞作二次校验；
  4. 主进程 URL 残缺时，回退 renderer 邻近 URL。

输出：
  work/resolved_cards.json  每卡：时长/点赞/文案/命中 oid/流键/下载 URL/状态
  控制台明细表。
"""
import json, os, sys

WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work")

def load(name):
    p = os.path.join(WORK, name)
    if os.path.exists(p):
        return json.load(open(p, encoding="utf-8"))
    return None

uia = load("uia_cards.json") or {"cards": []}
pairs_doc = load("main_pairs.json") or {"rows": []}
mm = load("mem_model2.json") or []

# renderer 记录：oid / encfilekey / m 三键索引
by_oid, by_ek, by_m = {}, {}, {}
for r in mm:
    d = r.get("decoded") or {}
    oid = str(d.get("object_id") or r.get("oid") or "") or None
    med = (r.get("media") or {}).get("20302") or {}
    rec = {"oid": oid, "len": d.get("vid_len"), "like": d.get("cur_like_count"),
           "nonce": r.get("nonce"), "index": r.get("index"),
           "pos": d.get("feed_pos"), "page": d.get("page_num"),
           "scid": d.get("scid"), "aid": d.get("aid"),
           "ek": med.get("encfilekey"), "m": med.get("m"),
           "url": med.get("raw_url", "")}
    if oid:
        by_oid[oid] = rec
    if rec["ek"]:
        by_ek[rec["ek"]] = rec
    if rec["m"]:
        by_m[rec["m"]] = rec

pairs = []
seen_oid = set()
full_oids = [p["object_id"] for p in pairs_doc["rows"] if len(p["object_id"]) >= 19]
for p in pairs_doc["rows"]:
    if p["kind"] != "20302":
        continue
    oid = p["object_id"]
    # 丢弃被截断的后缀副本（已并入同记录的完整 oid）
    if any(f != oid and f.endswith(oid) for f in full_oids):
        continue
    ek = p["encfilekey"]
    m = p.get("m", "")
    rend = by_oid.get(oid) or by_ek.get(ek) or by_m.get(m)
    meta = p.get("meta") or {}
    join_src = ("oid" if by_oid.get(oid) else
                "ek" if by_ek.get(ek) else
                "m" if by_m.get(m) else None)
    if rend is not None:
        plen = rend["len"] if rend["len"] is not None else meta.get("vid_len")
        plike = rend["like"] if rend["like"] is not None else meta.get("like")
        pidx = rend["index"]
        ppos = rend["pos"] if rend["pos"] is not None else meta.get("feed_pos")
        ppage = rend["page"] if rend["page"] is not None else meta.get("page_num")
        pscid = rend.get("scid") or meta.get("scid")
        paid = rend.get("aid") or meta.get("aid")
        pnonce = rend.get("nonce")
        purl = rend.get("url", "")
    else:
        plen = meta.get("vid_len"); plike = meta.get("like")
        pidx = None; ppos = meta.get("feed_pos"); ppage = meta.get("page_num")
        pscid = meta.get("scid"); paid = meta.get("aid"); pnonce = None; purl = ""
    url = p.get("raw_url", "") or purl
    pairs.append({"oid": oid, "key": ek, "raw_url": url, "m": m, "token": p.get("token", ""),
                  "len": plen, "like": plike, "nonce": pnonce, "index": pidx,
                  "pos": ppos, "page": ppage, "scid": pscid, "aid": paid,
                  "join_src": join_src, "n": p.get("n", 0)})
    seen_oid.add(oid)

# renderer 独有、主进程未出现但自带邻近 URL 的记录，补进候选池
for oid, rend in by_oid.items():
    if oid in seen_oid or not rend.get("url"):
        continue
    pairs.append({"oid": oid, "key": rend["ek"] or "", "raw_url": rend["url"],
                  "m": rend["m"] or "", "token": "", "len": rend["len"], "like": rend["like"],
                  "nonce": rend["nonce"], "index": rend["index"], "pos": rend["pos"],
                  "page": rend["page"], "scid": rend["scid"], "aid": rend["aid"],
                  "join_src": "renderer", "n": 0})

by_len = {}
for x in pairs:
    if x["len"] is not None:
        by_len.setdefault(int(x["len"]), []).append(x)

LIKE_TOL = 0.15
used = set()
rows = []
ready = 0; matched = 0; like_ok = 0; idx_ok = 0; ambiguous = 0

for c in uia["cards"]:
    sec = c.get("seconds", c.get("Seconds"))
    li = c.get("like_int", c.get("LikeInt"))
    idx = c.get("index", c.get("Index"))
    rec = None
    cands = [x for x in by_len.get(sec, []) if x["oid"] not in used]

    def like_pen(x):
        if x["like"] is None or li is None:
            return 999.0
        return abs(int(x["like"]) - int(li)) / max(int(x["like"]), 1)

    def idx_pen(x):
        if x["index"] is None or idx is None:
            return 50  # 序号未知，中性偏后
        return 0 if int(x["index"]) == int(idx) else 100 + abs(int(x["index"]) - int(idx))

    if cands:
        cands.sort(key=lambda x: (idx_pen(x), like_pen(x)))
        top = cands[0]
        if len(cands) > 1:
            second = cands[1]
            near_like = (like_pen(top) <= LIKE_TOL and like_pen(second) <= LIKE_TOL)
            near_idx = (top["index"] is not None and second["index"] is not None
                        and abs(idx_pen(top) - idx_pen(second)) <= 1)
            if near_like and near_idx:
                top = None; ambiguous += 1
        rec = top

    check = "-"; pcheck = "-"; note = ""
    if rec:
        used.add(rec["oid"]); matched += 1
        if rec["like"] is not None and li is not None:
            base = max(int(rec["like"]), 1)
            if abs(int(rec["like"]) - int(li)) / base < LIKE_TOL:
                like_ok += 1; check = "Y"
            else:
                check = "N"
        if rec["index"] is not None and idx is not None:
            if int(rec["index"]) == int(idx):
                idx_ok += 1; pcheck = "Y"
            elif abs(int(rec["index"]) - int(idx)) <= 1:
                pcheck = "~"
            else:
                pcheck = "N"
        url = rec["raw_url"] or ""
        url_ok = ("sign=" in url and "basedata=" in url)
        if url_ok:
            status = "ready"; ready += 1
        else:
            status = "pending"; url = ""
            note = "流地址不完整（缺签名参数），重新悬停取流"
        if not note and check == "N":
            note = "点赞与卡片不符，可能错配"
    else:
        if ambiguous and not note:
            note = "多条同时长候选，序号/点赞无法区分"
        url = ""; status = "pending"

    rows.append({
        "index": idx, "duration": c.get("duration", c.get("Duration")),
        "seconds": sec, "like": c.get("like", c.get("Like")), "desc": c.get("desc", c.get("Desc")),
        "status": status, "note": note,
        "object_id": rec["oid"] if rec else None, "nonce": rec["nonce"] if rec else None,
        "key20302": rec["key"] if rec else None, "url": url,
        "like_check": check, "pos_check": pcheck,
        "mem_index": rec["index"] if rec else None, "page": rec["page"] if rec else None,
        "scid": rec["scid"] if rec else None, "join_src": rec["join_src"] if rec else None,
    })

out = {"total": len(rows), "matched": matched, "ready": ready, "like_ok": like_ok,
       "idx_ok": idx_ok, "ambiguous": ambiguous, "rows": rows}
json.dump(out, open(os.path.join(WORK, "resolved_cards.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=1)

print(f"卡片 {len(rows)}  命中 {matched}  ready {ready}  点赞一致 {like_ok}  序号一致 {idx_ok}  歧义 {ambiguous}\n")
print(f"{'idx':<4} {'dur':<6} {'like':<8} {'st':<7} {'lk':<3} {'ix':<3} {'src':<9} {'oid':<20} desc")
for r in rows:
    d = (r["desc"] or "")[:16]
    print(f"{str(r['index']):<4} {r['duration']:<6} {str(r['like']):<8} {r['status']:<7} "
          f"{r['like_check']:<3} {r['pos_check']:<3} {str(r['join_src']):<9} {str(r['object_id']):<20} {d}")
