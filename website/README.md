# `website/`

Public marketing site for Syrus, served at **https://syrus-ai.dev** via
**GitHub Pages**.

This is a **Next.js 15** app (App Router + Tailwind v4 + Motion) that builds to
a fully static site (`output: "export"`). No server runs in production — Pages
just serves the static files.

Public docs live in [`src/content/docs/`](./src/content/docs/) and are rendered
by the active Next.js site at `/docs`.
Bundled plugin pages render their canonical product documentation directly from
`plugins/<name>/docs/syrus_docs/*.md`. A plugin may own multiple files; its
name-matching file is the introduction and the page links to every additional
document.

## Develop

```bash
cd website
npm install
npm run dev        # http://localhost:3000
```

## Build (what Pages runs)

```bash
npm run sync-release   # refresh lib/release.json from the latest GH release (optional; network)
npm run sync-release:check # validate committed release metadata without network/writes
npm run build          # emits the static site to website/out/
```

`out/` is deployed by [`.github/workflows/deploy-website.yml`](../.github/workflows/deploy-website.yml)
(build → `actions/upload-pages-artifact` → `actions/deploy-pages`). It runs on
pushes to `website/**`, on `workflow_dispatch`, and as the final step of a
release (`release.yml` → `publish-website`).

## How it works

- **Downloads** point at GitHub's stable latest-release permalinks
  (`releases/latest/download/Syrus.dmg`), so they always
  serve the newest release with no rebuild. The version + file sizes shown on
  `/download` are display-only, baked into `lib/release.json` by
  `npm run sync-release` (the workflow runs it each build).
- **Open-source onboarding** (`components/demo.tsx`) closes the homepage with
  static calls to download, read the docs, browse GitHub, and file issues. The
  site has no message collection backend.
- **Custom domain** is set by `public/CNAME` (`syrus-ai.dev`). The apex/`www`
  DNS must point at GitHub Pages, and the domain must be set in the repo's
  Pages settings.

## Content

Copy lives in `lib/site.ts` (hero, workflow steps, feature pillars, entry
points). Pages are under `src/app/` (Next.js App Router, `src/` directory
layout). Public documentation lives in `src/content/docs/` and is statically
rendered at `/docs`.

## Information Architecture

The current static site is intentionally small:

| Page/section           | Path                                     | Purpose                                                                                                                        |
| ---------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Home                   | `src/app/page.tsx`                       | Marketing landing page assembled from hero, product video, workflow, feature, entry-point, and open-source onboarding sections |
| Control plane          | `src/app/control-plane/page.tsx`         | Product-positioning page comparing raw agent sessions with the durable Syrus harness around agents                             |
| Download               | `src/app/download/page.tsx`              | Desktop and CLI release downloads                                                                                              |
| Docs                   | `src/app/docs/**`, `src/content/docs/**` | Public documentation rendered from canonical markdown files                                                                    |
| Open-source onboarding | `components/demo.tsx`                    | Static download, docs, GitHub, and issue-tracker calls to action                                                               |
| Product copy           | `lib/site.ts`                            | Source of truth for hero copy, workflow steps, feature pillars, and entry points                                               |

Plugin READMEs are not website content. Keep operator-facing plugin prose in
the plugin's `docs/syrus_docs/` directory so the application docs search and
public website always use the same source.

Marketing-page copy lives in `lib/site.ts`, while reusable chrome copy lives in
the typed locale dictionaries in `lib/chrome.ts`. Prefer updating that shared copy over scattering
parallel wording through components.

**Convention: A feature is not done if the user-facing page that explains it is stale.**
Every PR that adds or changes product behavior should update the relevant page
or shared copy in `website/`, or say explicitly in the PR body why no update is
needed.
