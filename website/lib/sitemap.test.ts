import assert from "node:assert/strict";
import test from "node:test";
import { sitemapEntries } from "./sitemap.ts";
import { LocalePublication } from "./locales.ts";

test("emits each real localized URL with matching absolute alternates", () => {
  const publication = new LocalePublication(["en", "de"]);
  const entries = sitemapEntries(
    [{ href: "/plugins/example", locales: ["en", "de"] }],
    [{ href: "/docs/example" }],
    [],
    publication,
  );
  const pluginEntries = entries.filter(({ url }) => url.includes("plugins/example"));

  assert.deepEqual(pluginEntries, [
    {
      url: "https://syrus-ai.dev/de/plugins/example/",
      alternates: { languages: {
        en: "https://syrus-ai.dev/plugins/example/",
        de: "https://syrus-ai.dev/de/plugins/example/",
        "x-default": "https://syrus-ai.dev/plugins/example/",
      } },
    },
    {
      url: "https://syrus-ai.dev/plugins/example/",
      alternates: { languages: {
        en: "https://syrus-ai.dev/plugins/example/",
        de: "https://syrus-ai.dev/de/plugins/example/",
        "x-default": "https://syrus-ai.dev/plugins/example/",
      } },
    },
  ]);
  assert.equal(entries.some(({ url }) => url.includes("/la/")), false);
});

test("filters supported but unpublished locale variants", () => {
  const entries = sitemapEntries(
    [{ href: "/plugins/example", locales: ["en", "de", "la"] }],
    [],
  );
  const pluginEntries = entries.filter(({ url }) => url.includes("plugins/example"));

  assert.deepEqual(pluginEntries.map(({ url }) => url), [
    "https://syrus-ai.dev/de/plugins/example/",
    "https://syrus-ai.dev/plugins/example/",
  ]);
  assert.deepEqual(pluginEntries[0]?.alternates.languages, {
    en: "https://syrus-ai.dev/plugins/example/",
    de: "https://syrus-ai.dev/de/plugins/example/",
    "x-default": "https://syrus-ai.dev/plugins/example/",
  });
});

test("deduplicates slash variants and preserves export-style trailing slashes", () => {
  const entries = sitemapEntries([{ href: "/plugins" }], [{ href: "/plugins/" }]);
  assert.equal(entries.filter(({ url }) => url === "https://syrus-ai.dev/plugins/").length, 1);
  assert.ok(entries.every(({ url }) => url.endsWith("/")));
});
