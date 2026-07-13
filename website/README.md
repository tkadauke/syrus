# `website/`

Public marketing site for Syrus, served at **https://syrus-ai.dev** via
**GitHub Pages**.

This is a **Next.js 15** app (App Router + Tailwind v4 + Motion) that builds to
a fully static site (`output: "export"`). No server runs in production — Pages
just serves the static files.

> **Note:** this replaced an earlier Astro/Starlight content scaffold, which is
> preserved under [`_archive-astro/`](./_archive-astro/) (its markdown docs were
> not migrated). See the PR that introduced this directory for the rationale.

## Develop

```bash
cd website
npm install
npm run dev        # http://localhost:3000
```

## Build (what Pages runs)

```bash
npm run sync-release   # refresh lib/release.json from the latest GH release (optional; network)
npm run build          # emits the static site to website/out/
```

`out/` is deployed by [`.github/workflows/deploy-website.yml`](../.github/workflows/deploy-website.yml)
(build → `actions/upload-pages-artifact` → `actions/deploy-pages`). It runs on
pushes to `website/**`, on `workflow_dispatch`, and as the final step of a
release (`release.yml` → `publish-website`).

## How it works

- **Downloads** point at GitHub's stable latest-release permalinks
  (`releases/latest/download/Syrus.dmg` and `Syrus-Setup.exe`), so they always
  serve the newest release with no rebuild. The version + file sizes shown on
  `/download` are display-only, baked into `lib/release.json` by
  `npm run sync-release` (the workflow runs it each build).
- **Demo form** (`components/demo.tsx`) POSTs to a self-hosted SMTP endpoint at
  `NEXT_PUBLIC_API_BASE` (default `https://api.syrus-ai.dev`), which sends the
  branded confirmation + team notification. If that endpoint is unreachable,
  the form falls back to a `mailto:` — the site itself stays fully static.
- **Custom domain** is set by `public/CNAME` (`syrus-ai.dev`). The apex/`www`
  DNS must point at GitHub Pages, and the domain must be set in the repo's
  Pages settings.

## Content

Marketing copy lives in `lib/site.ts` (hero, workflow steps, feature
pillars, entry points). Pages are under `src/app/` (Next.js App Router,
`src/` directory layout). Product documentation source lives under
`src/content/docs/`; keep it current with product behavior even while the
static docs publishing surface is being migrated. The markdown under
`src/pages/` and `src/site-pages/` is legacy positioning copy retained for
content migration reference; `_archive-astro/` remains the frozen
pre-migration snapshot.

## Information Architecture

The current static site is intentionally small:

| Page/section | Path | Purpose |
| --- | --- | --- |
| Home | `src/app/page.tsx` | Marketing landing page assembled from hero, workflow, feature, entry-point, and demo sections |
| Download | `src/app/download/page.tsx` | Desktop and CLI release downloads |
| Request a demo | `components/demo.tsx` | Demo/contact form with mailto fallback |
| Product copy | `lib/site.ts` | Source of truth for hero copy, workflow steps, feature pillars, and entry points |

Copy lives in `lib/site.ts`. Prefer updating that shared copy over scattering
parallel wording through components.

**Convention: A feature is not done if the user-facing page that explains it is stale.**
Every PR that adds or changes product behavior should update the relevant page
or shared copy in `website/`, or say explicitly in the PR body why no update is
needed.
