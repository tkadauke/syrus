import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { defaultLocale, isLocale } from "../lib/locales.ts";

const output = path.join(process.cwd(), "out");

function htmlFiles(directory: string): string[] {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return htmlFiles(entryPath);
    return entry.name.endsWith(".html") ? [entryPath] : [];
  });
}

const generatedHtml = htmlFiles(output);
assert.ok(generatedHtml.length > 0, "static export must contain HTML pages");

for (const file of generatedHtml) {
  const relativePath = path.relative(output, file);
  const routePrefix = relativePath.split(path.sep)[0];
  const expectedLocale = isLocale(routePrefix) ? routePrefix : defaultLocale;
  const html = fs.readFileSync(file, "utf8");
  assert.match(html, new RegExp(`<html[^>]*lang="${expectedLocale}"`), `${relativePath} must render lang=${expectedLocale}`);
}

assert.equal(fs.existsSync(path.join(output, "en")), false, "canonical English must remain unprefixed");
assert.equal(fs.existsSync(path.join(output, "de")), false, "unpublished German pages must not be exported");
assert.equal(fs.existsSync(path.join(output, "la")), false, "unpublished Latin pages must not be exported");
