import json, sys, html

src = sys.argv[1]
out = sys.argv[2]
d = json.load(open(src))

P1 = """review-evidence-matches-head run-before-review-barrier epic-linear-children implemented-or-approved-without-pr
stale-workflow-fails-job merge-train-merged-implies-evidence locked-landing-recheck lock-acquisition-nil-owner
superseded-active-runtime-work one-active-run-per-step serial-barrier-ready-set epic-wide-workflow-conflict
dependencies-respected landing-queue-order single-live-executor""".split()
P2 = """classifier-executor-agreement reconciler-respects-domain queued-step-without-run queued-workflow-without-first-run
active-step-with-terminal-runs job-state-matches-latest-workflow terminal-workflow-active-descendants
running-workflow-with-failed-step running-workflow-nothing-left two-definitions-of-active-step
review-loop-needs-work-no-repair queued-run-without-claim merge-train-failed-member-landed stranded-landing-job
landing-work-job-state in-place-retry-reconciled-away""".split()

rank = {}
for i, x in enumerate(P1): rank[x] = ("p1", i)
for i, x in enumerate(P2): rank[x] = ("p2", i)

for it in d["items"]:
    if it["status"] == "done":
        it["tier"] = "done"
    elif it["status"] == "by-design":
        it["tier"] = "design"
    elif it["id"] in rank:
        it["tier"] = rank[it["id"]][0]
    elif it["class"] == "a":
        it["tier"] = "p3"
    elif it["class"] == "b":
        it["tier"] = "p4"
    else:
        it["tier"] = "p5"
    it["order"] = rank.get(it["id"], ("", 999))[1]

missing = [x for x in P1 + P2 if x not in {i["id"] for i in d["items"]}]
if missing:
    print("UNKNOWN IDS", missing); sys.exit(1)

data = json.dumps({"areas": d["areas"], "items": d["items"], "commit": d.get("generated_from_commit"), "needs_you": d.get("needs_you", [])}).replace("</", "<\\/")
tpl = open(sys.argv[3]).read()
open(out, "w").write(tpl.replace("__DATA__", data))
counts = {}
for it in d["items"]:
    counts[it["tier"]] = counts.get(it["tier"], 0) + 1
print(counts)
