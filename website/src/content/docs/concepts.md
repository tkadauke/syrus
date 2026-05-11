---
title: Concepts
description: Job, Workflow, Step, Run — the four moving parts of Syrus and how they fit together.
---

<!-- STUB. Implementation issue: "Docs: getting-started + concepts."

     Content brief:
     - Job vs Workflow vs Step vs Run — what each one is, when each
       is created, what its state machine looks like.
     - AASM states for each: queued / running / succeeded / failed /
       cancelled.
     - Trigger kinds: initial, pr_comment, ci_failure, retry,
       manual, rebase, resume, local_dev.
     - The MCP sidecar (comment / mark_failed / submit_summary).
     - Distill from ARCHITECTURE.md; don't reinvent.
-->

# Concepts

Syrus has four moving parts: **Job**, **Workflow**, **Step**,
**Run**. Each maps to a database row; each has its own state
machine.

<!-- TODO: full content distilled from ARCHITECTURE.md -->
