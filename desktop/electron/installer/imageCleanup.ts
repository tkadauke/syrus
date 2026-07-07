import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { execEnv, findDockerBinary } from "./dockerRuntime.js"

const execFileAsync = promisify(execFile)

// Every backend update pulls a fresh ~7.6GB image and nothing used to remove
// the superseded one — after a handful of app updates the Docker VM disk
// fills up with dead syrus-backend images while Syrus's own data volume is
// tiny. This module retires exactly those local leftovers after an update is
// confirmed healthy. "Superseded" means SAME-REPOSITORY siblings only:
// images whose full repository (registry + namespace + name — the ref minus
// the tag) equals the pinned ref's repository, under a different tag. A
// basename match alone is NOT enough — a developer's locally built
// `syrus-backend:dev-abc` or a fork's `ghcr.io/somefork/syrus-backend:x`
// lives in a different repository than the pinned
// `ghcr.io/tkadauke/syrus-backend` and must survive a routine update.
// Removal is a plain, unforced `docker image rm` per ref — an image still
// referenced by any container fails politely and stays; nothing outside that
// scope is ever touched.
export const SYRUS_IMAGE_BASENAMES = ["syrus-backend", "syrus-local"] as const

// Splits `ghcr.io:443/owner/syrus-backend:0.1.2` into repository + tag.
// The tag separator is the last colon AFTER the last slash — a plain
// `lastIndexOf(":")` would split inside a registry host:port.
const splitRef = (ref: string): { repository: string; tag: string | null } => {
  const trimmed = ref.trim()
  const lastSlash = trimmed.lastIndexOf("/")
  const lastColon = trimmed.lastIndexOf(":")
  if (lastColon > lastSlash) {
    return { repository: trimmed.slice(0, lastColon), tag: trimmed.slice(lastColon + 1) }
  }
  return { repository: trimmed, tag: null }
}

// A tagless ref (pre-pin installs floated on :latest) means :latest.
export const normalizeImageRef = (ref: string): string => {
  const { repository, tag } = splitRef(ref)
  return `${repository}:${tag ?? "latest"}`
}

// True only for refs whose repository basename is exactly syrus-backend or
// syrus-local, under any registry/namespace prefix. Exact-segment match on
// purpose: a user's unrelated `my-syrus-backend` image must never qualify.
// Dangling `<none>` rows are excluded — they aren't removable by ref anyway.
export const isSyrusManagedImageRef = (ref: string): boolean => {
  const { repository, tag } = splitRef(ref)
  if (repository === "" || repository === "<none>" || tag === "<none>") {
    return false
  }

  const basename = repository.split("/").pop() ?? ""
  return (SYRUS_IMAGE_BASENAMES as readonly string[]).includes(basename)
}

// Pure filter core: given the `docker images --format '{{.Repository}}:{{.Tag}}'`
// listing, which refs are superseded syrus images? Only SAME-REPOSITORY
// siblings of the pin qualify — the ref's repository (registry + namespace +
// name) must equal the pinned ref's repository, with a different tag.
// Anything in another repository (a dev's local `syrus-backend:dev-abc`
// build, a fork registry's image) is untouched. Removes nothing without a
// pinned ref (no pin means we cannot know what "current" is), and always
// keeps the pin plus anything a running container references. The syrus
// basename check stays as defense-in-depth: even a same-repository match
// must still look like one of our images.
export const supersededSyrusImages = (
  imageRefs: string[],
  { pinnedRef, inUseRefs }: { pinnedRef: string | null; inUseRefs: string[] }
): string[] => {
  if (!pinnedRef) {
    return []
  }

  const pinnedRepository = splitRef(pinnedRef).repository
  const keep = new Set([pinnedRef, ...inUseRefs].map(normalizeImageRef))
  return imageRefs.filter(
    (ref) =>
      isSyrusManagedImageRef(ref) &&
      splitRef(ref).repository === pinnedRepository &&
      !keep.has(normalizeImageRef(ref))
  )
}

// Docker's human sizes ("7.62GB", "581MB") use decimal units. Best-effort:
// unknown formats just drop out of the total.
const sizeToBytes = (size: string): number | null => {
  const match = size.trim().match(/^([\d.]+)\s*(kB|MB|GB|TB|B)$/)
  if (!match) {
    return null
  }

  const factor = { B: 1, kB: 1e3, MB: 1e6, GB: 1e9, TB: 1e12 }[match[2] as "B" | "kB" | "MB" | "GB" | "TB"]
  return Number(match[1]) * factor
}

const formatBytes = (bytes: number): string => {
  if (bytes >= 1e9) {
    return `${(bytes / 1e9).toFixed(1)}GB`
  }
  if (bytes >= 1e6) {
    return `${Math.round(bytes / 1e6)}MB`
  }
  return `${Math.round(bytes / 1e3)}kB`
}

export type ImageCleanupResult = { removed: string[]; reclaimedDisplay: string | null }

// Exec shell around the pure filter: list local images (with docker's own
// size column for the log line), list refs running containers use, remove
// each superseded ref with a plain `docker image rm`. Individual failures
// are ignored by design — an in-use image just refuses politely — and the
// whole pass is best-effort: it must never fail the update that invoked it.
export const removeSupersededSyrusImages = async ({
  pinnedRef,
  log = () => {}
}: {
  pinnedRef: string | null
  log?: (line: string) => void
}): Promise<ImageCleanupResult> => {
  const nothing: ImageCleanupResult = { removed: [], reclaimedDisplay: null }
  try {
    if (!pinnedRef) {
      return nothing
    }

    const binary = await findDockerBinary()
    if (!binary) {
      return nothing
    }

    const run = (args: string[]) => execFileAsync(binary, args, { env: execEnv(), timeout: 60_000 })

    // One listing feeds both the filter (ref) and the log line (size).
    const { stdout: imagesOut } = await run(["images", "--format", "{{.Repository}}:{{.Tag}}|{{.Size}}"])
    const refs: string[] = []
    const sizes = new Map<string, string>()
    for (const line of imagesOut.split(/\r?\n/)) {
      const trimmed = line.trim()
      if (trimmed === "") {
        continue
      }

      const separator = trimmed.lastIndexOf("|")
      const ref = separator === -1 ? trimmed : trimmed.slice(0, separator)
      refs.push(ref)
      if (separator !== -1) {
        sizes.set(ref, trimmed.slice(separator + 1))
      }
    }

    const { stdout: psOut } = await run(["ps", "--format", "{{.Image}}"])
    const inUseRefs = psOut.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)

    const removed: string[] = []
    let reclaimedBytes = 0
    for (const ref of supersededSyrusImages(refs, { pinnedRef, inUseRefs })) {
      try {
        await run(["image", "rm", ref])
        removed.push(ref)
        const size = sizes.get(ref)
        reclaimedBytes += (size && sizeToBytes(size)) || 0
        log(`[image-cleanup] removed superseded image ${ref}${size ? ` (${size})` : ""}`)
      } catch {
        log(`[image-cleanup] left ${ref} in place (still referenced or remove failed)`)
      }
    }

    // Per-image sizes overlap on shared layers, so the total is a ceiling.
    const reclaimedDisplay = reclaimedBytes > 0 ? `up to ~${formatBytes(reclaimedBytes)}` : null
    if (removed.length > 0) {
      log(`[image-cleanup] removed ${removed.length} superseded syrus image(s)${reclaimedDisplay ? `, reclaiming ${reclaimedDisplay}` : ""}`)
    }

    return { removed, reclaimedDisplay }
  } catch {
    return nothing
  }
}
