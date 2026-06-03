# `website/`

Source for the public Syrus website at `syrusai.dev` (domain TBD).

See [`docs/plans/website.md`](../docs/plans/website.md) for the
full plan: tech stack, hosting, content strategy, launch gating.

## Status

**Content skeleton plus IA contract.** This directory contains markdown
files laying out the intended sitemap; Starlight (the Astro-based docs
framework) isn't configured yet. The plan doc lists the implementation
issues that fill in:

- Starlight + Astro setup (`astro.config.mjs`, `package.json`,
  Actions deploy workflow)
- Home page (`src/pages/index.astro`) with the hero visual
- Page-by-page docs content

The local evaluation path is canonical at
`/docs/deployment/try-it-locally`; do not recreate a separate
`/evaluate` page.

## Structure

```
website/
├── src/
│   ├── content/
│   │   └── docs/                 # Starlight content (auto-routes to /docs/*)
│   │       ├── what-is-syrus.md
│   │       ├── why-use-syrus.md
│   │       ├── getting-started.md
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

## Content Inventory

| Existing content | Decision | Target / notes |
| --- | --- | --- |
| `src/pages/index.md` | Rewrite later | Keep as Home. Replace markdown stub with custom Astro hero, proof visual, moat sections, screenshots, and deployment CTAs. |
| `src/pages/about.md` | Preserve | Keep for naming story, history, maintainer, and footer link. Do not mix product docs into this page. |
| `src/pages/evaluate.md` | Deleted / merged | Duplicate of local evaluation docs. Canonical content now lives at `/docs/deployment/try-it-locally`. |
| `src/content/docs/what-is-syrus.md` | New target | Product overview and 30-second flow. |
| `src/content/docs/why-use-syrus.md` | New target | Positioning and product reasons. |
| `src/content/docs/getting-started.md` | Preserve / refine | First practical path chooser. Link to local evaluation and deployment docs. |
| `src/content/docs/concepts.md` | Preserve | Terminology and state-machine model. Avoid duplicating this in Architecture. |
| `src/content/docs/features.md` | New target | Feature map and canonical destination list. Update when major feature docs are added. |
| `src/content/docs/configuration.md` | Preserve | Canonical page for `.syrus.yml`, user settings, repo settings, env vars, credentials. |
| `src/content/docs/workflows.md` | Preserve | Canonical page for templates, trigger kinds, step chains, and DAG roadmap. |
| `src/content/docs/architecture.md` | Preserve / keep concise | Maintainer-level system map. Link to repo `ARCHITECTURE.md` for the deep dive. |
| `src/content/docs/api.md` | Preserve stub | Keep as API placeholder until the public REST API ships. |
| `src/content/docs/recipes.md` | Retitle / preserve | Canonical task page for how-tos and recipes. |
| `src/content/docs/troubleshooting.md` | Preserve | Canonical failure-mode page. Move debugging snippets here instead of scattering them. |
| `src/content/docs/faq.md` | Preserve | Short competitive/security/cost answers. Move long explanations into feature docs when they grow. |
| `src/content/docs/deployment/index.md` | Preserve | Three-path deployment chooser. |
| `src/content/docs/deployment/try-it-locally.md` | Preserve / canonicalize | Sole local-evaluation page. |
| `src/content/docs/deployment/docker-compose.md` | Preserve | Recommended full-product setup path. |
| `src/content/docs/deployment/kubernetes.md` | Preserve | Cluster operations path; keep hard-mode framing. |

## Contributing

Pick an issue with the `syrus` label that references a `website/`
path; fill in the content matching the stub's brief. Cross-reference
the plan doc when in doubt about scope.

Don't add new top-level sections without updating the plan doc
first — the sidebar is part of the navigation contract.
