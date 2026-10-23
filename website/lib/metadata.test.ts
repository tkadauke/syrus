import assert from "node:assert/strict";
import test from "node:test";
import { localizedMetadata, siteJsonLd } from "./metadata.ts";
import { LocalePublication } from "./locales.ts";

test("builds canonical and x-default metadata for an English-only page", () => {
  const metadata = localizedMetadata({ locale: "en", pathname: "/docs", title: "Docs", description: "English docs" });

  assert.equal(metadata.alternates?.canonical, "/docs/");
  assert.deepEqual(metadata.alternates?.languages, { en: "/docs/", "x-default": "/docs/" });
  assert.equal(metadata.openGraph?.url, "/docs/");
  assert.equal(metadata.openGraph?.description, "English docs");
  assert.equal(metadata.twitter?.description, "English docs");
});

test("localizes copy and advertises only real English and German equivalents", () => {
  const publication = new LocalePublication(["en", "de"]);
  const metadata = localizedMetadata({
    locale: "de",
    pathname: "/control-plane",
    title: { en: "Control Plane", de: "Steuerung" },
    description: { en: "Durable work", de: "Beständige Arbeit" },
    availableLocales: ["en", "de"],
    publication,
  });

  assert.equal(metadata.title, "Steuerung");
  assert.equal(metadata.alternates?.canonical, "/de/control-plane/");
  assert.deepEqual(metadata.alternates?.languages, {
    en: "/control-plane/",
    de: "/de/control-plane/",
    "x-default": "/control-plane/",
  });
  assert.equal(Object.hasOwn(metadata.alternates?.languages ?? {}, "la"), false);
});

test("rejects metadata for an unpublished locale and filters unpublished alternates", () => {
  assert.throws(
    () => localizedMetadata({ locale: "de", pathname: "/", title: "Deutsch", description: "Deutsch" }),
    /unpublished locale: de/,
  );
  const metadata = localizedMetadata({
    locale: "en", pathname: "/", title: "English", description: "English",
    availableLocales: ["en", "de", "la"],
  });
  assert.deepEqual(metadata.alternates?.languages, { en: "/", "x-default": "/" });
});

test("localizes structured-data descriptions", () => {
  const jsonLd = siteJsonLd("de", { en: "English", de: "Deutsch" });
  assert.equal(jsonLd["@graph"][1].description, "Deutsch");
  assert.equal(jsonLd["@graph"][1].inLanguage, "de");
});
