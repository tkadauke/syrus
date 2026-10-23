import assert from "node:assert/strict";
import test from "node:test";
import {
  isLocale,
  isPublishedLocale,
  localizedHref,
  localizedStaticParams,
} from "./locales.ts";

test("validates supported and published locales independently", () => {
  assert.equal(isLocale("en"), true);
  assert.equal(isLocale("de"), true);
  assert.equal(isLocale("la"), true);
  assert.equal(isLocale("fr"), false);
  assert.equal(isPublishedLocale("en"), true);
  assert.equal(isPublishedLocale("de"), false);
  assert.equal(isPublishedLocale("la"), false);
});

test("localizes internal paths but preserves English, fragments, and external URLs", () => {
  assert.equal(localizedHref("/docs", "de"), "/de/docs");
  assert.equal(localizedHref("/#features", "de"), "/de/#features");
  assert.equal(localizedHref("/", "la"), "/la/");
  assert.equal(localizedHref("/docs", "en"), "/docs");
  assert.equal(localizedHref("#features", "de"), "#features");
  assert.equal(localizedHref("https://example.com/docs", "de"), "https://example.com/docs");
  assert.equal(localizedHref("mailto:hello@example.com", "de"), "mailto:hello@example.com");
  assert.equal(localizedHref("//cdn.example.com/file", "de"), "//cdn.example.com/file");
});

test("generates no prefixed parameters until a non-English locale is published", () => {
  assert.deepEqual(localizedStaticParams(), []);
});
