---
title: Observability
description: Where to inspect performance, SQL, operational logs, browser errors, backend exceptions, and live MySQL state.
---

# Observability

Syrus records several kinds of operational evidence. The goal is to make
debugging possible without shelling into pods first.

## Performance

Admin Performance shows slow browser traces, requests, jobs, SQL statements,
phases, and event writes for the current revision. Request details can group
SQL under the request and under the deepest active phase, so a slow endpoint is
traceable to the actual work it performed.

Use it when:

- a page takes seconds to load,
- a background job blocks throughput,
- a SQL statement appears repeatedly,
- a frontend interaction feels slow.

For SQL rows, the admin API can run `EXPLAIN` and safe `EXPLAIN ANALYZE`
against captured statements when the query is safe to analyze. The UI presents
the plan in a visual modal for easier index and join diagnosis.

## Operational Logs

Operational logs are searchable, structured events for normal system activity:
worker actions, sidecar events, plugin calls, preview lifecycle events, and
other runtime notices. They are useful when nothing crashed but behavior still
looks wrong.

## Browser Errors

Browser errors capture client-side exceptions with path, user agent, revision,
stack, and request context. They are separate from performance data because a
fast page can still crash in the renderer.

The admin log UI can file a Syrus Job directly from a browser error and attach
the full log entry to the prompt, so the agent starts with the evidence that
was captured.

## Backend Exceptions

Backend exceptions capture request and job failures with class, message,
backtrace, runtime context, and revision. Treat them as the first place to look
when the UI shows a 500.

## Activity and Reconciler Logs

The activity log records important state transitions and why Syrus made them.
The reconciler log records repair decisions for stale runs, orphaned queued
work, worker-death recovery, closed-job cleanup, and similar consistency work.

Use these logs when a Job seems to move by itself, when a workflow is retried,
or when a queued item disappears.

## Live MySQL

The optional MySQL admin plugin is for installations that use MySQL instead of
SQLite. When enabled, it shows live process list information, connection state,
slow log status, statement digests when permissions allow it, and guarded query
kill actions.

This view runs live MySQL commands on demand. It is not a replacement for
retained performance logs.

## Retention

Operational evidence is retained for bounded recent debugging, not forever.
Exact retention can vary by deployment and log stream. The admin UI should be
treated as a live incident tool; copy durable conclusions into Jobs, PRs, or
docs when they matter long term.

## Practical Debug Paths

For a slow page:

1. Open Admin Performance and find the request path.
2. Inspect grouped SQL and phase timing for that request.
3. Explain the slowest SQL if the statement is safe.
4. Check Browser traces if backend time is low but the page still feels slow.

For a stuck Job:

1. Open the Job workflow tab.
2. Check the latest workflow, Work Unit status, and pause reason.
3. Read the activity and reconciler logs around the same time.
4. Inspect provider availability and admission-control status if the work is
   waiting rather than failed.
