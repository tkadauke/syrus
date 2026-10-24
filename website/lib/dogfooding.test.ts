import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { marketingFor } from "./marketing.ts"

const websiteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const read = (relativePath: string) => fs.readFileSync(path.join(websiteRoot, relativePath), "utf8")

test("publishes the corrected dogfooding audit consistently", () => {
  const dogfooding = read("src/content/docs/dogfooding.md")
  const blog = read("src/content/blog/2026-10-24-introducing-syrus.md")
  const hero = read("components/hero.tsx")
  assert.match(dogfooding, /4,451 landed originals, 4,346/)
  assert.match(dogfooding, /through September 27 is 97\.3%/)
  assert.equal(dogfooding.match(/95\.1%/g)?.length, 1)
  assert.match(dogfooding, /95\.3% were Syrus work/)
  assert.match(dogfooding, /70\.9% arrived through pull requests/)
  assert.match(blog, /October 24 audit, 97\.6%/)
  assert.match(hero, />97\.6%<\/span>/)
  assert.match(marketingFor("en").hero.metricBody, /landed original pull requests/)
  assert.doesNotMatch(`${blog}\n${hero}`, /95\.1%/)
  assert.doesNotMatch(dogfooding, /roughly 45% Syrus changes/)
})
