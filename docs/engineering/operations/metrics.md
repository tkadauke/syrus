# Metrics operations

## Scraping

```
GET /metrics
Authorization: Bearer <admin API token>
```

Same admin token as `/api/v1/admin/*`, so there is no new credential to manage.
Non-admin tokens get 403; anonymous requests get 401.

Deployments that prefer to restrict the endpoint at the network layer — a
NetworkPolicy admitting only the Prometheus pod — can set
`SYRUS_METRICS_PUBLIC=1` to drop the token requirement. That is safe here
because every metric is an aggregate with bounded labels: there is nothing
identifying to leak (see *Cardinality* below).

The endpoint is cheap on purpose. It renders in-memory state and runs no
aggregate queries, because an endpoint that queried the queue tables would get
slow at exactly the moment those tables are the problem.

## Readiness and Alert Rules

`GET /readyz` is the unauthenticated readiness probe for load balancers and
container health checks. It uses `AppApi::ReadinessChecks` without per-user
credential checks, so it verifies web/database boot, fresh registered Solid
Queue worker heartbeats, pause state, storage, and instance-level GitHub App
setup without requiring a browser session or decrypting an operator's personal
credentials. The route returns `503` when any required check is in error; `/up`
remains the lighter Rails boot/liveness check.

The Docker image and the single-host Compose `web` service both probe
`/readyz`. Compose installations can inspect it with:

```
curl -fsS http://localhost:3000/readyz
```

Prometheus alert rules for the canonical operational alerts ship at
`config/prometheus/syrus-alert-rules.yml`:

- queue oldest age over 30 minutes, using
  `syrus_global_queue_oldest_age_seconds`;
- provider circuit open, using `syrus_provider_circuit_state`;
- recurring job staleness over twice each configured schedule interval, using
  `syrus_recurring_job_last_success_seconds`.

**Scope:** currently served by the **web** role only. Worker pods run several
forked processes that share no memory, so scraping them needs a separate
exporter with a shared store; that is a later step. Until then, counters
incremented on workers are not yet exported, unless declared `cluster: true`
(see *Counting across processes* below) -- this currently applies to
`syrus_admission_decisions_total`, which is incremented wherever an admission
decision is made (see *Workers and admission* below), including on workers.
`syrus_worker_cpu_percent`/`syrus_worker_memory_percent`/`syrus_worker_disk_percent`
are not affected by this gap: they are sampled from the
`worker_host_health_samples` table (rows every worker writes on its own
heartbeat) into the same web-served cache the other GLOBAL gauges use, so
they are visible today even though no worker pod is scraped directly.
