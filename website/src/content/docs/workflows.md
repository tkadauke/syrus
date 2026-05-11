---
title: Workflows
description: Templates that define what an agent does for each trigger kind.
---

<!-- STUB. Implementation issue: "Docs: configuration + workflows +
     architecture."

     Content brief:
     - What a Workflow template is (a sequence of Steps)
     - Built-in templates: Initial, PrFeedback, Rebase, Retry,
       Manual, Resume, LocalDev
     - Step kinds: prepare, implement, summarize, push, pr_open,
       agent_rebase, summarize_amend, etc.
     - How a workflow template maps to a per-Job DAG
     - Forward pointer: v2/v3 DAG with agent-authored edges (the
       roadmap entry)
-->

# Workflows

A Workflow template is a sequence of Steps. Each trigger kind
(`initial`, `pr_comment`, `ci_failure`, `rebase`, etc.) has its
own template that determines what the agent does.

<!-- TODO: full content -->
