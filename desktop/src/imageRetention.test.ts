import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { supersededSyrusImages } from "../electron/installer/imageCleanup"
import {
  IMAGE_RETENTION_DAYS,
  activeRetention,
  readImageRetention,
  retentionAfterUpdate,
  writeImageRetention
} from "../electron/installer/imageRetention"

// NY24 (decided B): after a backend update, keep the image the update
// replaced until the next successful update or for 7 days, so a rollback does
// not need a multi-GB re-pull.

const now = new Date("2026-11-23T12:00:00Z")
const day = 24 * 60 * 60 * 1000

describe("retentionAfterUpdate", () => {
  it("retains the replaced image for seven days", () => {
    expect(retentionAfterUpdate("ghcr.io/tkadauke/syrus-backend:0.1.1", "ghcr.io/tkadauke/syrus-backend:0.1.2", now)).toEqual({
      ref: "ghcr.io/tkadauke/syrus-backend:0.1.1",
      until: new Date(now.getTime() + IMAGE_RETENTION_DAYS * day).toISOString()
    })
    expect(IMAGE_RETENTION_DAYS).toBe(7)
  })

  it("retains nothing when there was no previous pin or it did not change", () => {
    expect(retentionAfterUpdate(null, "ghcr.io/tkadauke/syrus-backend:0.1.2", now)).toBeNull()
    expect(retentionAfterUpdate("ghcr.io/tkadauke/syrus-backend:0.1.2", "ghcr.io/tkadauke/syrus-backend:0.1.2", now)).toBeNull()
  })
})

describe("activeRetention", () => {
  const retention = { ref: "ghcr.io/tkadauke/syrus-backend:0.1.1", until: new Date(now.getTime() + day).toISOString() }

  it("is active until its deadline and expired after it", () => {
    expect(activeRetention(retention, now)).toEqual(retention)
    expect(activeRetention(retention, new Date(now.getTime() + 2 * day))).toBeNull()
  })

  it("treats a missing or unreadable deadline as expired", () => {
    expect(activeRetention(null, now)).toBeNull()
    expect(activeRetention({ ref: retention.ref, until: "not a date" }, now)).toBeNull()
  })
})

describe("supersededSyrusImages with a retained image", () => {
  const listing = [
    "ghcr.io/tkadauke/syrus-backend:0.1.2",
    "ghcr.io/tkadauke/syrus-backend:0.1.1",
    "ghcr.io/tkadauke/syrus-backend:0.1.0"
  ]

  it("keeps the retained previous image and removes anything older", () => {
    expect(
      supersededSyrusImages(listing, {
        pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
        inUseRefs: [],
        retainedRef: "ghcr.io/tkadauke/syrus-backend:0.1.1"
      })
    ).toEqual(["ghcr.io/tkadauke/syrus-backend:0.1.0"])
  })

  it("removes the previous image once nothing retains it", () => {
    expect(
      supersededSyrusImages(listing, { pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2", inUseRefs: [], retainedRef: null })
    ).toEqual(["ghcr.io/tkadauke/syrus-backend:0.1.1", "ghcr.io/tkadauke/syrus-backend:0.1.0"])
  })
})

describe("the retention record", () => {
  let dir: string | null = null
  afterEach(async () => {
    if (dir) {
      await rm(dir, { recursive: true, force: true })
      dir = null
    }
  })

  it("round-trips through the state directory, and clearing removes it", async () => {
    dir = await mkdtemp(path.join(tmpdir(), "image-retention-"))
    const retention = { ref: "ghcr.io/tkadauke/syrus-backend:0.1.1", until: now.toISOString() }

    await writeImageRetention(dir, retention)
    expect(JSON.parse(await readFile(path.join(dir, "image-retention.json"), "utf8"))).toEqual(retention)
    expect(await readImageRetention(dir)).toEqual(retention)

    await writeImageRetention(dir, null)
    expect(await readImageRetention(dir)).toBeNull()
  })

  it("reads a missing or corrupt record as no retention", async () => {
    dir = await mkdtemp(path.join(tmpdir(), "image-retention-"))
    expect(await readImageRetention(dir)).toBeNull()
  })
})
