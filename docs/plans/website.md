# Public website for Syrus

_Captured 2026-05-11 from the chat conversation that produced PR
`website/skeleton-and-plan`. Lives here as the canonical plan;
implementation is fanned out to individual `syrus`-tagged issues._

## Why this exists

When Syrus goes public, it needs a web presence: a home page that
makes the pitch, a clear path to evaluation, documentation for
deployment and configuration, and a small amount of marketing copy
to drive adoption.

**Launch is gated on Syrus going public**, not on the website being
finished. We build the website now so it's ready when the rest of the
project is.

## Strategic framing

Lead with the **moat from the competitive scan** (see
`docs/competitive-landscape-2026-05-10.md`): small-team self-host
with real multi-tenancy, BYOK, no vendor lock-in. The home-page lede
needs to be unambiguous so the right audience self-selects.

Working lede:

> **Syrus** — Self-hosted, multi-tenant, BYOK alternative to Devin
> and Copilot Coding Agent. Owns the deterministic plumbing —
> clones, branches, PRs, cleanup — so the agent only writes code.
> Multi-user from day one. Runs on your hardware, your Anthropic
> key, your audit log.

Refine before launch but keep that shape: what it is, who it's for,
what makes it different.

## Hosting

**GitHub Pages with custom domain.**

- Content lives in the same repo as the code (under `website/`)
- GitHub Actions builds on push to `main`, deploys to Pages
- Custom domain via CNAME — points your domain at
  `tkadauke.github.io`
- No infra to manage, no exposed home network, free

Self-hosting on the maintainer's k3s was considered and rejected
(home-network exposure risk). Vercel / Netlify / Mintlify were
considered and rejected (vendor dependence, contradicts the
self-host pitch).

## Domain

**Recommended: `syrusai.dev`**.

- One fewer character than `syrus-ai.dev`
- Hyphens in tech-brand domains are old-school
- Reads as a single brand word ("Syrus AI")

Fallback: `syrus-ai.dev` if the unhyphenated form parses
awkwardly to native readers.

Not in play: `syrus.dev` (taken), `syrus.ai` ($150k).

## Tech stack

**Starlight (Astro)** as the framework.

- Markdown-driven content (contributors write `.md`)
- Static-site output — served by GitHub Pages with no Node runtime
- Custom landing-page support alongside auto-generated docs
- Sidebar auto-generation from folder structure (less config drift)
- Sensible defaults; minimal theme work needed

VitePress was considered as a near-equivalent. Starlight wins on the
"docs site with a custom landing page" use case specifically;
VitePress is more "docs site for a JS library."

## Repository layout

```
syrus/
├── docs/
│   └── plans/website.md           # this file
├── website/                       # the site source
│   ├── README.md                  # contributor guide for the website
│   ├── src/
│   │   ├── content/
│   │   │   └── docs/              # Starlight content (auto-routes to /docs/*)
│   │   │       ├── getting-started.md
│   │   │       ├── concepts.md
│   │   │       ├── deployment/
│   │   │       │   ├── index.md
│   │   │       │   ├── try-it-locally.md
│   │   │       │   ├── docker-compose.md
│   │   │       │   └── kubernetes.md
│   │   │       ├── configuration.md
│   │   │       ├── workflows.md
│   │   │       ├── architecture.md
│   │   │       ├── api.md
│   │   │       ├── recipes.md
│   │   │       ├── troubleshooting.md
│   │   │       └── faq.md
│   │   └── pages/                 # custom routes
│   │       ├── index.md           # home (becomes .astro once Starlight lands)
│   │       ├── evaluate.md        # 3-step eval
│   │       └── about.md           # naming, project history
│   └── public/
│       └── CNAME                  # added when domain is purchased
└── .github/workflows/
    └── deploy-website.yml         # build + deploy to GH Pages
```

Content right next to the code that documents it. Contributors
editing a feature update its docs in the same PR.

## Home page design

Top to bottom:

1. **Hero**: tagline (Publilius epigraph "Bis dat qui cito dat."),
   one-paragraph pitch (working lede above), primary CTA
   *"Try it locally →"* and secondary *"Star on GitHub"*.
   - **Visual proof**: a faded example issue card on the left, an
     arrow, a faded example PR-diff card on the right. Makes the
     `issue → PR` shape concrete without prose. Sourced from the
     project's own dogfooding history (a real Syrus PR).
2. **What is Syrus, 30-second version** — diagram showing the
   `issue → poller → agent → PR` flow plus one short paragraph.
3. **Why Syrus** — three cards distilled from the competitive moat:
   *"You own the keys"* / *"Self-host on your cluster"* /
   *"Multi-user from day one"*.
4. **Show the work** — screenshots of a Job page (transcript + diff
   + PR link) and the dashboard. More persuasive than prose. Compare
   Trigger.dev and Inngest landing pages for reference styling.
5. **Honest status** — *"Syrus has been working on itself since day
   2. N PRs merged via Syrus's own pipeline. One production tenant;
   permissive MIT license; early-adopter friendly."* (Fill N at copy
   time.)
6. **Get started** — three buttons mirroring the deployment paths:
   *Try it locally* / *Deploy with Docker Compose* / *Run on
   Kubernetes*.
7. **Footer** — GitHub, license, naming-story link.

## Three deployment paths

The site presents three paths in order of complexity. Each has its
own audience and its own docs page under `/docs/deployment/`.

| Path | Audience | Setup time | Use case |
| --- | --- | --- | --- |
| **1. Try it locally** | Anyone curious | ~60s | Single Docker container running `bin/syrus dev` against your local repo. Pre-onboarding evaluation. |
| **2. Run it locally for real** | Developers / small teams | ~5min | Docker Compose with web + worker + MySQL. Full polling + PR flow against real GitHub repos. |
| **3. Deploy to a cluster** | Teams running real infra | ~30min | Helm chart for k3s/k8s ([#182](https://github.com/tkadauke/syrus/issues/182)). Production-grade. |

A fourth implicit path — `git clone && bundle install && bin/dev`
— is a footnote under path #2 for Ruby developers who already have
the toolchain. Not surfaced as a peer column to keep the table
focused.

Honest framing for path #3: "this is the hard mode; took the
maintainer days 2-5 just to bootstrap on a real cluster." Steers
casual users toward Compose; builds trust through transparency.

## The 3-step "Try it locally" page

The most important page after the home page. Gets a visitor from
"I clicked the link" to "I see the agent doing something useful on
my own code" in under 3 minutes.

```bash
# 1. Get an Anthropic API key
export ANTHROPIC_API_KEY=sk-ant-...

# 2. Run Syrus against any local repo
docker run --rm \
  -v $(pwd):/work \
  -e ANTHROPIC_API_KEY \
  ghcr.io/tkadauke/syrus:latest dev /work \
  --prompt "Add a CHANGELOG.md with a placeholder entry for the next release"

# 3. Inspect the diff Syrus produced
# (printed to stdout; apply with `git apply` if you like it)
```

No git clone of Syrus. No Ruby installation. No database setup.
The OCI image bundles everything; `bin/syrus dev` (already shipping
via PR #188) runs synchronously and writes the diff to stdout.
Visitor evaluates Syrus against their own code in 60 seconds.

Below the three steps: a sample output (formatted diff + a few
lines of transcript). Below that: *"Like what you see? Deploy
Syrus to your cluster →"* linking to the Docker Compose path.

## Documentation structure

Standard OSS-docs outline. Most sections reuse content from
existing in-repo docs (`ARCHITECTURE.md`, `ROADMAP.md`,
`CLAUDE.md`) rather than duplicating.

- **Getting started**: installation, first run, basic concepts.
- **Concepts**: Job / Workflow / Step / Run terminology, AASM
  states, trigger kinds. Mostly distilled from `ARCHITECTURE.md`.
- **Deployment**: the three paths (one page each) plus a "Source
  install (Ruby)" subsection.
- **Configuration**: `.syrus.yml`, per-user settings, per-repo
  settings.
- **Workflows**: how templates work, how to write your own.
- **Architecture**: link to `ARCHITECTURE.md` plus a short
  visual overview.
- **API**: REST API reference once that lands (issue #196).
- **Recipes**: common patterns — *"handle a failing test"*,
  *"respond to PR review"*, etc.
- **Troubleshooting**: common issues, log locations, debug
  commands.
- **FAQ**: vs Devin, vs OpenHands, security model, BYOK details,
  costs.

## Licensing

**MIT.** Add `LICENSE` file at repo root, `## License` section in
README. No drama.

Rationale: maximum adoption, no constraint on commercial use, no
ambiguity. Trade-off considered (AGPL as poison pill against a
hosted-Syrus-as-a-service competitor) is not worth the adoption
penalty — the moat is "self-host," not "hosted SaaS."

## Launch gating

Public website launch happens **with** Syrus's public launch. The
website is ready first; it sits behind the private repo until
Syrus is open-sourced.

Pre-launch criteria for Syrus itself (not the website):

- The OCI image exists and the 3-step eval flow works end-to-end
- Helm chart or polished Docker Compose for production deploy exists
- License decided and committed
- 2-3 production tenants beyond the maintainer have run it for a
  week without disaster
- The competitive-scan doc (`docs/competitive-landscape-2026-05-10.md`)
  is reviewed and sanitized — it's internal strategy that should
  *not* be public-facing as-is
- A bunch of moat-deepening features land first (per the maintainer
  2026-05-11)

The website work is independent of all of those. We build it now
so it's ready when Syrus is.

## Implementation issues to fan out

After this skeleton PR lands, file the following as
`syrus`-tagged implementation issues for parallel agents:

1. **Set up Starlight + GitHub Actions deploy.** Add
   `astro.config.mjs`, `package.json`, `tsconfig.json`. Configure
   Starlight with the sidebar structure from the layout above. Add
   `.github/workflows/deploy-website.yml` that builds on push to
   main and deploys to GitHub Pages. Verify a build succeeds and
   the site renders locally.
2. **Home page content + hero visual.** Write the `index.astro`
   for the home page including the issue → diff hero visual. Use
   a real Syrus PR as the example.
3. **3-step "Try it locally" eval page.** Write `evaluate.astro`
   with the three-command flow + sample output. Depends on the OCI
   image existing (separate issue).
4. **About page.** Naming story, project history (sketch on a plane
   2026-05-01, working on itself since day 2), maintainer.
5. **Docs: getting-started + concepts.** First-pass content for
   `/docs/getting-started` and `/docs/concepts`. Distill from
   `README.md` + `ARCHITECTURE.md`.
6. **Docs: deployment (3 paths + source install).** Content for
   `/docs/deployment/{index,try-it-locally,docker-compose,kubernetes}.md`
   plus the Ruby-dev footnote.
7. **Docs: configuration + workflows + architecture.** Distill from
   in-repo sources.
8. **Docs: recipes + troubleshooting + FAQ.** Greenfield content.
9. **OCI image for `bin/syrus dev` (3-step eval target).**
   Dockerfile that bundles Ruby + Syrus + dependencies, with
   `bin/syrus dev` as the entrypoint. Pushes to
   `ghcr.io/tkadauke/syrus`. This is what the 3-step eval page
   depends on.
10. **Docker Compose for path #2.** `docker-compose.yml` at repo
    root bringing up web + worker + MySQL (+ Solid Cable if
    needed). Documented in `/docs/deployment/docker-compose.md`.

Issues 1, 9, 10 are highest priority — they unblock the rest.
Issues 2-8 are content work, can run in parallel once Starlight is
configured (issue 1).

## What this skeleton PR contains

- This plan doc (`docs/plans/website.md`).
- The `website/` directory with stub markdown for every page in the
  intended sitemap. Each stub has a short content brief explaining
  what the page should cover.
- `website/README.md` explaining the layout and pointing at this
  plan + the implementation issues.

What this PR does **not** contain:
- Starlight / Astro setup (`package.json`, `astro.config.mjs`,
  etc.). Filed as issue #1 above.
- GitHub Actions deploy workflow. Same issue.
- Actual page content. Filed as issues #2–#8.
- CNAME file. Added when the domain is purchased.

The split keeps this PR a reviewable skeleton — directories and
intent — while the actual implementation work parallelizes via
agents.
