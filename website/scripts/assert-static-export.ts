import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { defaultLocale, isLocale } from "../lib/locales.ts"

const output = path.join(process.cwd(), "out")

function htmlFiles(directory: string): string[] {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(directory, entry.name)
    if (entry.isDirectory()) return htmlFiles(entryPath)
    return entry.name.endsWith(".html") ? [entryPath] : []
  })
}

const generatedHtml = htmlFiles(output)
assert.ok(generatedHtml.length > 0, "static export must contain HTML pages")

for (const file of generatedHtml) {
  const relativePath = path.relative(output, file)
  const routePrefix = relativePath.split(path.sep)[0]
  const expectedLocale = isLocale(routePrefix) ? routePrefix : defaultLocale
  const html = fs.readFileSync(file, "utf8")
  assert.match(html, new RegExp(`<html[^>]*lang="${expectedLocale}"`), `${relativePath} must render lang=${expectedLocale}`)
}

assert.equal(fs.existsSync(path.join(output, "en")), false, "canonical English must remain unprefixed")
assert.equal(fs.existsSync(path.join(output, "de")), true, "published German pages must be exported")
assert.equal(fs.existsSync(path.join(output, "la")), false, "unpublished Latin pages must not be exported")

const homeHtml = fs.readFileSync(path.join(output, "index.html"), "utf8")
assert.match(homeHtml, /<link rel="canonical" href="https:\/\/syrus-ai\.dev\/"/)
assert.match(homeHtml, /<link rel="alternate" hrefLang="en" href="https:\/\/syrus-ai\.dev\/"/)
assert.match(homeHtml, /<link rel="alternate" hrefLang="x-default" href="https:\/\/syrus-ai\.dev\/"/)
assert.doesNotMatch(homeHtml, /hrefLang="la"/)

const germanHomeHtml = fs.readFileSync(path.join(output, "de", "index.html"), "utf8")
assert.match(germanHomeHtml, /<html[^>]*lang="de"/)
assert.match(germanHomeHtml, /Zum Inhalt springen/)
assert.match(germanHomeHtml, /Syrus-Startseite/)
assert.match(germanHomeHtml, /href="\/de\/plugins"/)
assert.match(germanHomeHtml, /Zeig Syrus die Aufgabe/)
assert.match(germanHomeHtml, /href="\/de\/#how"/)
assert.match(germanHomeHtml, /href="\/docs"[^>]*>Dokumentation \(Englisch\)/)
assert.doesNotMatch(germanHomeHtml, /href="\/de\/docs/)
assert.equal(fs.existsSync(path.join(output, "de", "docs")), false, "untranslated docs must not be exported under German routes")

const germanControlPlaneHtml = fs.readFileSync(path.join(output, "de", "control-plane", "index.html"), "utf8")
assert.match(germanControlPlaneHtml, /<title>Steuerzentrale · Syrus<\/title>/)
assert.match(germanControlPlaneHtml, /aria-label="Syrus-Steuerzentrale/)
assert.match(germanControlPlaneHtml, /href="\/de\/plugins"/)
assert.match(germanControlPlaneHtml, /href="#comparison"/)
assert.match(germanControlPlaneHtml, /Was Syrus ist \(Englisch\)/)
assert.match(germanControlPlaneHtml, /href="\/docs\/what-is-syrus"/)

const germanDownloadHtml = fs.readFileSync(path.join(output, "de", "download", "index.html"), "utf8")
assert.match(germanDownloadHtml, /<title>Syrus herunterladen · Syrus<\/title>/)
assert.match(germanDownloadHtml, /Zurück zur Startseite/)
assert.match(germanDownloadHtml, />Herunterladen<\/a>/)

const sitemapXml = fs.readFileSync(path.join(output, "sitemap.xml"), "utf8")
assert.match(sitemapXml, /<xhtml:link rel="alternate" hreflang="x-default" href="https:\/\/syrus-ai\.dev\/" \/>/)
assert.doesNotMatch(sitemapXml, /hreflang="la"/)
assert.match(sitemapXml, /hreflang="de"/)
