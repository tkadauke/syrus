# Alertmanager Investigations

The Alertmanager Investigations plugin polls Alertmanager for firing alerts and
files read-only investigation Jobs for alerts that explicitly opt in with a
resolvable runbook.

Enable the plugin from Admin > Plugins and configure either `ALERTMANAGER_URL`
or the plugin's Alertmanager URL setting. If Alertmanager requires bearer auth,
set `ALERTMANAGER_BEARER_TOKEN` in the process environment.

The plugin reads `/api/v2/alerts` with active, unsilenced, uninhibited alerts
only, and it still ignores any returned alert whose Alertmanager status is not
active. It does not poll raw Prometheus and it does not create a Job for each
poll. A Job is created only when a firing alert has a `runbook_url`, `runbook`,
or `runbookURL` annotation that resolves to a file in a registered GitHub
repository URL:

- `https://github.com/OWNER/REPO/blob/REF/path/to/runbook.md`
- `https://raw.githubusercontent.com/OWNER/REPO/REF/path/to/runbook.md`

If the runbook URL is absent, points at an unregistered repository, or the file
cannot be read, no Job is created. Failed resolutions are recorded for the
fingerprint rate-limit window so an invalid alert does not repeatedly fetch the
same runbook. One malformed alert does not prevent later alerts from being
processed. That fail-closed behavior is the safety property: adding autonomy
for an alert requires adding a reviewed runbook link.

The prompt sent to `InvestigationJobs::Creator` contains the full alert payload
and the resolved runbook. The resulting Job is a `direct` investigation Job, so
it produces a narrative report instead of a pull request. Alert investigations
are read-only: if a runbook reaches a decision or remediation point, the report
should escalate with one of the core reason codes (`needs_human_decision`,
`lacks_authority`, `remediation_failed`, or `unsafe_to_proceed`) rather than
performing the action.

Code-level guards limit noise and unsafe duplication:

- One investigation per Alertmanager fingerprint per rate-limit window
  (`rate_limit_minutes`, default 30).
- No second open investigation for the same host. The host is read from the
  configured host label (`host_label`, default `instance`) and then falls back
  through common labels such as `host` and `node`. Host names are compared
  without a trailing metrics port.
- At most `max_jobs_per_tick` Jobs (default 5) are created by one poll, and no
  repository may have more than `max_open_jobs_per_repository` open alert
  investigations (default 10). Alerts deferred by the repository cap are
  recorded for the fingerprint window without fetching the runbook content
  again on each poll.
