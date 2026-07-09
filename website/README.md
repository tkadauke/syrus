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

Copy lives in `lib/site.ts` (hero, workflow steps, feature pillars, entry
points) and `lib/legal.ts` (Impressum + privacy). Pages are under `app/`.

## Information Architecture

The site surfaces three content kinds: marketing pages (what, why, proof),
documentation (deployment, configuration, API), and legal.

Key pages and docs (source-of-truth markdown under `src/`):

| Page | Path | Purpose |
| --- | --- | --- |
| What is Syrus? | `src/pages/what-is-syrus.md` | Product positioning |
| Why use Syrus? | `src/pages/why-use-syrus.md` | Adoption rationale and fit check |
| Getting Started | `src/content/docs/getting-started.md` | First deployment walkthrough |
| Troubleshooting | `src/content/docs/troubleshooting.md` | Common failure modes |

**Convention: A feature is not done if the user-facing page that explains it is stale.**
Every PR that adds or changes product behavior should update the relevant page
under `src/` or say explicitly in the PR body why no update is needed.
