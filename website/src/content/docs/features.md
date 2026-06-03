---
title: Feature docs
description: A map of Syrus product features and the docs pages that explain them.
---

# Feature docs

Use this page as the product-feature map. It points to the canonical docs
for each feature area so later content work has clear destinations instead
of creating nearly identical pages.

| Feature area | Canonical docs | Notes for later jobs |
| --- | --- | --- |
| GitHub issue delegation | [Getting Started](/docs/getting-started), [Configuration](/docs/configuration) | Keep trigger-label and repository-registration details here, not in a separate issue-ingestion page. |
| Job / Workflow / Step / Run model | [Concepts](/docs/concepts) | Terminology and state-machine content belongs here. |
| Workflow templates and trigger kinds | [Workflows](/docs/workflows) | Template behavior, step chains, retries, PR feedback, CI failure, rebase, manual, and local-dev flows belong here. |
| Repository preparation | [Configuration](/docs/configuration) | `.syrus.yml` and auto-detected setup commands belong here. |
| User and repository settings | [Configuration](/docs/configuration) | Keep provider selection, max turns, scheduling pause, and repo overrides together. |
| Deployment paths | [Deployment](/docs/deployment) | Keep local evaluation, Docker Compose, and Kubernetes under `deployment/`. |
| Local evaluation | [Try it locally](/docs/deployment/try-it-locally) | This is the only canonical local-eval page. Do not recreate `/evaluate`. |
| Scheduled tasks | [How-tos and recipes](/docs/recipes), [Workflows](/docs/workflows) | Keep how-to material in the recipes page; keep trigger/template reference in Workflows. |
| PR feedback handling | [How-tos and recipes](/docs/recipes), [Workflows](/docs/workflows) | Recipe for usage, Workflow page for mechanics. |
| CI failure repair | [How-tos and recipes](/docs/recipes), [Troubleshooting](/docs/troubleshooting) | Recipe for setup, Troubleshooting for failure modes. |
| MCP sidecar and PR summaries | [Concepts](/docs/concepts), [Architecture](/docs/architecture) | Keep user-facing summary behavior in Concepts; maintainer-level plumbing in Architecture. |
| Admin and external API | [REST API](/docs/api) | This remains a stub until the API is public. |

## Navigation order

The public docs should browse in this order:

1. [What is Syrus?](/docs/what-is-syrus)
2. [Why use Syrus?](/docs/why-use-syrus)
3. [Getting Started](/docs/getting-started)
4. [Concepts](/docs/concepts)
5. [Feature docs](/docs/features)
6. [How-tos and recipes](/docs/recipes)
7. [Troubleshooting](/docs/troubleshooting)
8. Reference pages: [Configuration](/docs/configuration),
   [Workflows](/docs/workflows), [Architecture](/docs/architecture),
   [REST API](/docs/api), and [FAQ](/docs/faq)

The home page should link into the first three docs pages and the three
deployment paths. Deep feature pages should link back to this map when a
reader needs to choose a destination.
