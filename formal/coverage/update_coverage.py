"""Small, explicit edits to formal/coverage/coverage.json.

usage: update_coverage.py <coverage.json> <edits.json>
edits.json: {"items": {"<id>": {field: value, ...}}, "needs_you": [ {...} ]  (appended, by id)}
"""
import json, sys
path, edits_path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
e = json.load(open(edits_path))
ids = {i["id"]: i for i in d["items"]}
for item_id, fields in e.get("items", {}).items():
    if item_id not in ids:
        sys.exit("unknown item " + item_id)
    ids[item_id].update(fields)
ny = d.setdefault("needs_you", [])
known = {q["id"] for q in ny}
for q in e.get("needs_you", []):
    if q["id"] in known:
        for existing in ny:
            if existing["id"] == q["id"]:
                existing.update(q)
    else:
        ny.append(q)
json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
print("ok", len(ny), "needs_you")
