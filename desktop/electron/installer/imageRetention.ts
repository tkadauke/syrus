import { readFile, rm, writeFile } from "node:fs/promises"
import path from "node:path"

// After a backend update the image it replaced is the only way back that does
// not need a multi-GB re-pull, which may be impossible offline. So it is kept
// for a while (NY24): until the next successful update replaces this record,
// or for IMAGE_RETENTION_DAYS, whichever comes first. The record lives in the
// install's state directory beside the .env that holds the pin.
export const IMAGE_RETENTION_DAYS = 7
const RETENTION_FILE = "image-retention.json"

export type ImageRetention = { ref: string; until: string }

// The record a successful update leaves: the replaced pin, kept for seven
// days. Nothing is kept when there was no earlier pin, or it did not change.
export const retentionAfterUpdate = (previousRef: string | null, newRef: string, now: Date = new Date()): ImageRetention | null => {
  if (!previousRef || previousRef === newRef) {
    return null
  }
  return { ref: previousRef, until: new Date(now.getTime() + IMAGE_RETENTION_DAYS * 24 * 60 * 60 * 1000).toISOString() }
}

// The retention still in force, or null once its deadline passed. An
// unreadable deadline counts as passed, so a corrupt record frees the space.
export const activeRetention = (retention: ImageRetention | null, now: Date = new Date()): ImageRetention | null => {
  if (!retention) {
    return null
  }
  const until = Date.parse(retention.until)
  return Number.isFinite(until) && until > now.getTime() ? retention : null
}

export const readImageRetention = async (dir: string): Promise<ImageRetention | null> => {
  try {
    const parsed = JSON.parse(await readFile(path.join(dir, RETENTION_FILE), "utf8")) as Partial<ImageRetention>
    return typeof parsed.ref === "string" && typeof parsed.until === "string" ? { ref: parsed.ref, until: parsed.until } : null
  } catch {
    return null
  }
}

// Writes the record, or removes it for null. Best-effort by contract, like the
// cleanup it feeds: losing the record only means the image is not kept.
export const writeImageRetention = async (dir: string, retention: ImageRetention | null): Promise<void> => {
  try {
    if (retention) {
      await writeFile(path.join(dir, RETENTION_FILE), `${JSON.stringify(retention)}\n`, "utf8")
    } else {
      await rm(path.join(dir, RETENTION_FILE), { force: true })
    }
  } catch {
    // Retention is a convenience; it must never fail an update.
  }
}
