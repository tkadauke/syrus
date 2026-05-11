---
title: Architecture
description: How Syrus fits together — polling, workers, the MCP sidecar, and the per-Run pipeline.
---

<!-- STUB. Implementation issue: "Docs: configuration + workflows +
     architecture."

     Content brief:
     - Don't re-write ARCHITECTURE.md — link to it for the
       canonical version
     - Short visual / diagrammatic overview of: poller -> Job ->
       Workflow -> Step -> Run -> agent -> PR
     - The polling decision (why no webhooks)
     - The MCP sidecar pattern
     - Per-user credential encryption
     - State machines (AASM): Job, Workflow, Step, Run
-->

# Architecture

A short visual overview of how Syrus fits together. For the
canonical, detailed reference see
[`ARCHITECTURE.md`](https://github.com/tkadauke/syrus/blob/main/ARCHITECTURE.md)
in the repository.

<!-- TODO: visual overview + content -->
