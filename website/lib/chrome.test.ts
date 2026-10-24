import assert from "node:assert/strict"
import test from "node:test"
import { chromeDictionaries, chromeFor, chromeHref, chromeLocales, isChromeLocale } from "./chrome.ts"

function leafShape(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(leafShape)
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, leafShape(child)]))
  }
  return typeof value
}

test("English and German chrome dictionaries are structurally complete", () => {
  assert.deepEqual(chromeLocales.sort(), ["de", "en"])
  assert.deepEqual(leafShape(chromeDictionaries.de), leafShape(chromeDictionaries.en))
  assert.equal(isChromeLocale("en"), true)
  assert.equal(isChromeLocale("de"), true)
  assert.equal(isChromeLocale("la"), false)
  assert.throws(() => chromeFor("la"), /No published chrome dictionary/)
  assert.match(chromeFor("de").plugins.searchPlaceholder, /Name/)
})

test("German chrome links local pages and keeps untranslated docs on English canonicals", () => {
  const links = chromeFor("de").nav.links.map((link) => ({
    label: link.label,
    href: chromeHref(link.href, "de", link.canonicalEnglish)
  }))

  assert.ok(links.some((link) => link.label === "Plugins" && link.href === "/de/plugins"))
  assert.ok(links.some((link) => link.label === "Dokumentation (Englisch)" && link.href === "/docs"))
  assert.equal(chromeHref("/#features", "de"), "/de/#features")
  assert.equal(chromeHref("https://github.com/tkadauke/syrus", "de"), "https://github.com/tkadauke/syrus")
})

test("visible and accessibility copy renders from the selected dictionary", () => {
  const german = chromeFor("de")
  const rendered = [
    german.skipToContent,
    german.nav.homeLabel,
    german.download.mac,
    german.docs.navigationLabel,
    german.plugins.searchLabel,
    german.plugins.empty
  ].join(" ")

  assert.match(rendered, /Zum Inhalt springen/)
  assert.match(rendered, /Syrus-Startseite/)
  assert.match(rendered, /Für Mac herunterladen/)
  assert.match(rendered, /Dokumentation \(Englisch\)/)
  assert.match(rendered, /Plugins durchsuchen/)
  assert.match(rendered, /Keine Plugins/)
})
