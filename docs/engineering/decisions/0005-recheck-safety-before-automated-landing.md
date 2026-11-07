---
id: ADR-0005
title: Recheck safety before automated landing
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0005: Recheck safety before automated landing

## Context

Approval, dependency, CI, pause, and branch state can change between queueing
and mutation. A prose review comment is also not a reliable approval signal.
The original single landing poller has evolved into landing queues, bundles,
and merge trains, but those races and authority boundaries remain.

## Decision

Automated landing is opt-in, has an explicit operator stop mechanism, uses
structured approval state, and rechecks current eligibility while holding the
final landing lock immediately before mutation. Earlier snapshots are
diagnostic or scheduling inputs, not authority to merge.

## Consequences

Landing may stop or defer after apparently passing an earlier check. Every new
landing mechanism must preserve the final locked recheck and pause controls;
cached state must be invalidated before that check. The policy survives changes
to the queueing mechanism that implements it.

## Evidence

- [Automated landing design issue](https://github.com/tkadauke/syrus/issues/210)
- [`LandingQueueProcessor`](../../../app/services/landing_queue_processor.rb)
- [Landing queue operator documentation](../../../config/syrus_docs/landing_queue.md)
- [State-machine landing convention](../conventions/state-machines.md)
