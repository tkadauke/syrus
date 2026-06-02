# `website/`

Source for the public Syrus website at `syrusai.dev` (domain TBD).

See [`docs/plans/website.md`](../docs/plans/website.md) for the
full plan: tech stack, hosting, content strategy, launch gating. See
[`docs/plans/website-information-architecture.md`](../docs/plans/website-information-architecture.md)
for the route-by-route IA, content inventory, and target pages for
follow-up website jobs.

## Status

The website is content-complete enough to be the canonical public
explanation of Syrus, but it is still framework-light. Pages are markdown
under `website/src/`; Starlight/Astro configuration, custom components,
screenshots, metadata generation, and hosting are intentionally separate
follow-up work.

Use this directory as the source of truth for public-facing product docs.
When product behavior changes, update the matching page here in the same
PR as the code change.

The local evaluation path is canonical at
`/docs/deployment/try-it-locally`; do not recreate a separate
`/evaluate` page.

## Structure

```
website/
├── src/
│   ├── content/
│   │   └── docs/                 # Starlight content (auto-routes to /docs/*)
│   │       ├── index.md
│   │       ├── getting-started.md
│   │       ├── what-is-syrus.md
│   │       ├── why-use-syrus.md
│   │       ├── concepts.md
│   │       ├── features.md
│   │       ├── deployment/       # the 3 paths (+ Ruby-dev footnote)
│   │       ├── configuration.md
│   │       ├── workflows.md
│   │       ├── architecture.md
│   │       ├── api.md
│   │       ├── recipes.md        # "How-tos and recipes"
│   │       ├── troubleshooting.md
│   │       └── faq.md
│   └── pages/                    # custom routes
│       ├── index.md              # home — becomes .astro once Starlight lands
│       └── about.md              # naming, project history
└── public/                       # static assets, CNAME, etc.
```

## Navigation Contract

The public website should browse in this order:

| Nav section | Canonical path | Purpose |
| --- | --- | --- |
| Home | `/` | Public landing page, proof visual, moat, and primary CTAs. |
| What is Syrus? | `/docs/what-is-syrus` | Plain product explanation and issue-to-PR flow. |
| Why use Syrus? | `/docs/why-use-syrus` | Self-host, BYOK, multi-user, and auditability positioning. |
| Getting started | `/docs/getting-started` | Choose an evaluation or deployment path and learn the first loop. |
| Concepts | `/docs/concepts` | Job, Workflow, Step, Run, states, trigger kinds, and MCP signals. |
| Feature docs | `/docs/features` | Product-feature map that points to canonical reference pages. |
| How-tos and recipes | `/docs/recipes` | Task-focused recipes: CI repair, PR feedback, scheduled jobs, custom workflows. |
| Troubleshooting | `/docs/troubleshooting` | Failure modes and debugging steps. |

Reference pages stay in the docs sidebar after the main learning path:
`/docs/configuration`, `/docs/workflows`, `/docs/architecture`,
`/docs/api`, `/docs/faq`, and `/docs/deployment/*`.

## Information Architecture

Public visitors should be able to answer four questions without reading
source:

| Question | Canonical pages |
| --- | --- |
| What is Syrus? | `src/pages/index.md`, `src/content/docs/what-is-syrus.md`, `src/content/docs/concepts.md` |
| Why would I use it? | `src/content/docs/why-use-syrus.md`, `src/content/docs/faq.md` |
| How do I try it? | `src/content/docs/getting-started.md`, `src/content/docs/deployment/try-it-locally.md` |
| What does operating it involve? | `src/content/docs/deployment/`, `src/content/docs/configuration.md`, `src/content/docs/recipes.md`, `src/content/docs/troubleshooting.md` |

Recommended sidebar order once Starlight lands:

1. Docs index
2. Getting Started
3. What is Syrus?
4. Why use Syrus?
5. Concepts
6. Features
7. Workflows
8. Configuration
9. Deployment
10. Recipes
11. Troubleshooting
12. Architecture
13. API
14. FAQ

## Contributing

Update website docs in the same PR as product changes. A feature is not done if the user-facing page that explains it is stale.

Keep existing pages current before adding new pages. Add a top-level docs
page only when the subject does not fit the navigation above, and update
this README when the navigation contract changes.
