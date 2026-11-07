# Delivery Tracks

Repositories can define landing branches, review phases, promotion, hotfix
sync, upstream export, external-PR ingestion, and explicit ref movement in
`.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: develop
      grade_phases:
        review: review_minimal
        landing: landing_minimal
      after_landing:
        sync_to: default
    hotfix:
      branch: main
      grade_phases:
        review: review_minimal
        landing: promotion
  promotion:
    enabled: true
    mode: auto_pr
    approval_required: false
    grade_phases: [promotion]
    repair_skill: integrate_release_branch
  hotfix_sync:
    enabled: true
    direction: release_to_development
    mode: auto
    grade_phases: [promotion]
    repair_skill: backport_release_hotfix
  upstream_export:
    enabled: true
    mode: per_job_pr
    after_local_approval: true
    target: upstream_intake
  ref_movement_actions:
    send_job_upstream:
      enabled: true
      source: { kind: job_branch }
      target: { kind: upstream_intake }
      mode: manual_pr
      grade_phases: [promotion]
    submit_branch_upstream:
      enabled: true
      mode: manual_pr
approval:
  job:
    required:
      owner: true
      peer_count: 1
  promotion:
    required:
      maintainer_count: 1
external_prs:
  ingest:
    enabled: true
    unknown: review_and_grade
    syrus_job_export: attach_or_create_job
    syrus_branch_export: create_epic
```

Without delivery configuration, Syrus uses one `default` track targeting the
repository default branch. Grade phase names are repository-defined. Select a
track at Job creation with the `delivery_track` parameter or by applying a
`syrus-track-<name>` issue label. Peer approval requires eligible approval from
someone other than the owner; configured owner and peer requirements are both
enforced.

Landing targets the selected track. Promotion moves the configured source
track to its target after required approval. Hotfix detection compares the
release and development lines and dispatches the configured sync without
turning the hotfix PR into ordinary review work. Upstream export sends an
approved Job branch, or an explicitly selected development branch, to the
configured upstream intake branch by PR.

External PR ingestion classifies structured Syrus provenance before branch
heuristics. Unknown external work is graded normally; recognized per-Job
exports attach to their existing Job when available; branch exports become one
review unit; promotion PRs are already tracked; manual hotfixes feed hotfix
sync. Operators can inspect or override first-time classification through the
delivery MCP tools.

The MCP surface includes `list_delivery_tracks`, `resolve_delivery_policy`,
`select_job_delivery_track`, `list_ref_movement_actions`,
`dispatch_ref_movement_action`, `read_ref_movement_status`,
`classify_pull_request`, and `ingest_pull_request`. Ref-movement actions are
configuration-gated and return their dispatched or blocked status.

Internal policy APIs, effective-base resolution, landing processing, PR-link
records, action audit records, poller mechanics, and payload construction live
in [delivery-track architecture](../../docs/engineering/architecture/delivery-tracks.md).
