# Alertmanager Investigations

The Alertmanager Investigations plugin polls Alertmanager for firing alerts and
files read-only investigation Jobs for alerts that explicitly opt in with a
resolvable runbook.

Enable the plugin from Admin > Plugins and configure either `ALERTMANAGER_URL`
or the plugin's Alertmanager URL setting. If Alertmanager requires bearer auth,
set `ALERTMANAGER_BEARER_TOKEN` in the process environment.

The plugin fails closed until `allowed_runbooks` is configured. Enter one
`OWNER/REPO:path/prefix` entry per line, for example:

```text
acme/infra:runbooks/production
acme/services:operations/runbooks
```

The plugin reads `/api/v2/alerts` with active, unsilenced, uninhibited alerts
only, and it still ignores any returned alert whose Alertmanager status is not
active. It does not poll raw Prometheus and it does not create a Job for each
poll. A Job is created only when a firing alert has a `runbook_url`, `runbook`,
or `runbookURL` annotation that resolves to a file in a registered GitHub
repository URL. The repository and path must match `allowed_runbooks`, the URL
must name the repository's default branch, and the file must begin with YAML
front matter that explicitly opts in:

```yaml
---
autonomous-investigation: true
---
```

Accepted URL shapes are:

- `https://github.com/OWNER/REPO/blob/REF/path/to/runbook.md`
- `https://raw.githubusercontent.com/OWNER/REPO/REF/path/to/runbook.md`

If the URL is absent, is outside the allowlist, names another ref, lacks the
opt-in marker, points at an unregistered repository, or cannot be read, the
alert is ignored. Runbooks larger than 32 KiB are also rejected rather than
partially followed. This makes autonomy require both an operator allowlist
change and a reviewed change on the repository's default branch.

The prompt sent to `InvestigationJobs::Creator` labels the alert payload as
untrusted evidence and caps its rendered size at 12 KiB. The resulting Job is a
`direct` investigation Job, so
it produces a narrative report instead of a pull request. Alert investigations
are read-only: if a runbook reaches a decision or remediation point, the report
should escalate with one of the core reason codes (`needs_human_decision`,
`lacks_authority`, `remediation_failed`, or `unsafe_to_proceed`) rather than
performing the action.

Two code-level guards limit noise and unsafe duplication:

- One investigation per Alertmanager fingerprint per rate-limit window
  (`rate_limit_minutes`, default 30).
- No second open investigation for the same host. The host is read from the
  configured host label (`host_label`, default `instance`) and then falls back
  through common labels such as `host` and `node`.
