import assert from "node:assert/strict"
import test from "node:test"
import { marketingFor } from "./marketing.ts"
import { controlPlaneFor } from "./control-plane-copy.ts"

test("publishes complete English and German marketing dictionaries", () => {
  for (const locale of ["en", "de"] as const) {
    const copy = marketingFor(locale)
    assert.equal(copy.workflow.steps.length, 6)
    assert.equal(copy.features.items.length, 7)
    assert.equal(copy.entries.items.length, 7)
    assert.equal(copy.media.shots.length, 3)
    assert.equal(copy.screenshot.jobs.length, 5)
    assert.equal(copy.demo.links.length, 3)
    assert.equal(controlPlaneFor(locale).cards.length, 6)
    assert.equal(controlPlaneFor(locale).loop.length, 5)
  }
})

test("German copy uses the approved register and domain terminology", () => {
  const serialized = JSON.stringify({ marketing: marketingFor("de"), controlPlane: controlPlaneFor("de") })
  assert.doesNotMatch(serialized, /\b(Ihnen|Ihr(?:e|en|er|em)?)\b/)
  assert.match(serialized, /\bdu\b/i)
  assert.match(serialized, /\bJobs\b/)
  assert.match(serialized, /\bWorkflows\b/)
  assert.match(serialized, /\bEpics\b/)
  assert.match(serialized, /\bLäufe\b/)
  assert.doesNotMatch(serialized, /\bRuns\b/)
})

test("refuses unpublished Latin marketing content", () => {
  assert.throws(() => marketingFor("la"), /No published marketing dictionary/)
  assert.throws(() => controlPlaneFor("la"), /No published control-plane dictionary/)
})
