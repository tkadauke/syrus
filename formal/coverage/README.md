# Coverage inventory

`coverage.json` lists every abnormal state the reconciler repairs (all
`classify_*` methods and every issue kind they emit), every property the
simulator scenarios defend, and the documented engine promises — one item each,
with its class (preventable / lag / external fault), likely producer, production
repair counts from one sample, and status (`open`, `partial`, `done`,
`by-design`).

`build_page.py` assigns each item a priority tier (the P1/P2 lists at the top
of the script; everything else falls back by class) and renders `template.html`
into a self-contained page:

```sh
python3 build_page.py coverage.json engine-proof-coverage.html template.html
```

When a finding lands, update its item's `status` and `done_by` here and its
entry in `../FINDINGS.md`.
