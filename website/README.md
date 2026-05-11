# `website/`

Source for the public Syrus website at `syrusai.dev` (domain TBD).

See [`docs/plans/website.md`](../docs/plans/website.md) for the
full plan: tech stack, hosting, content strategy, launch gating.

## Status

**Skeleton only.** This directory contains stub markdown files
laying out the intended sitemap; Starlight (the Astro-based docs
framework) isn't configured yet. The plan doc lists the
implementation issues that fill in:

- Starlight + Astro setup (`astro.config.mjs`, `package.json`,
  Actions deploy workflow)
- Home page (`src/pages/index.astro`) with the hero visual
- `evaluate.astro` for the 3-step eval flow
- Page-by-page docs content

Each stub here has a `<!-- TODO -->` block with a brief on what
content goes in it.

## Structure

```
website/
├── src/
│   ├── content/
│   │   └── docs/                 # Starlight content (auto-routes to /docs/*)
│   │       ├── getting-started.md
│   │       ├── concepts.md
│   │       ├── deployment/       # the 3 paths (+ Ruby-dev footnote)
│   │       ├── configuration.md
│   │       ├── workflows.md
│   │       ├── architecture.md
│   │       ├── api.md
│   │       ├── recipes.md
│   │       ├── troubleshooting.md
│   │       └── faq.md
│   └── pages/                    # custom routes
│       ├── index.md              # home — becomes .astro once Starlight lands
│       ├── evaluate.md           # 3-step eval
│       └── about.md              # naming, project history
└── public/                       # static assets, CNAME, etc.
```

## Contributing

Pick an issue with the `syrus` label that references a `website/`
path; fill in the content matching the stub's brief. Cross-reference
the plan doc when in doubt about scope.

Don't add new top-level sections without updating the plan doc
first — the sidebar is part of the navigation contract.
