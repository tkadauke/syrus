import { afterEach, describe, expect, it, vi } from "vitest"
import {
  isSyrusManagedImageRef,
  normalizeImageRef,
  removeSupersededSyrusImages,
  supersededSyrusImages
} from "../electron/installer/imageCleanup"

// imageCleanup.ts promisifies execFile AT MODULE LOAD, so the async mock is
// attached under the custom-promisify symbol (same pattern as
// dockerRuntime.test.ts).
const { execFileAsyncMock, execFileMock } = vi.hoisted(() => {
  const execFileAsyncMock = vi.fn(async (..._args: unknown[]) => ({ stdout: "", stderr: "" }))
  const execFileMock = Object.assign(vi.fn(), {
    [Symbol.for("nodejs.util.promisify.custom")]: execFileAsyncMock
  })
  return { execFileAsyncMock, execFileMock }
})

vi.mock("node:child_process", () => ({
  default: { execFile: execFileMock },
  execFile: execFileMock
}))

// Keep the exec-side tests hermetic: never probe the host for a real docker.
vi.mock("../electron/installer/dockerRuntime.js", () => ({
  findDockerBinary: vi.fn(async () => "/usr/local/bin/docker"),
  execEnv: vi.fn(() => ({}))
}))

afterEach(() => {
  execFileAsyncMock.mockReset()
  execFileAsyncMock.mockImplementation(async () => ({ stdout: "", stderr: "" }))
})

describe("normalizeImageRef", () => {
  it("keeps a fully-qualified ref intact", () => {
    expect(normalizeImageRef("ghcr.io/tkadauke/syrus-backend:0.1.2")).toBe("ghcr.io/tkadauke/syrus-backend:0.1.2")
  })

  it("treats a tagless ref as :latest (pre-pin installs floated on latest)", () => {
    expect(normalizeImageRef("ghcr.io/tkadauke/syrus-backend")).toBe("ghcr.io/tkadauke/syrus-backend:latest")
  })

  it("does not mistake a registry port for a tag separator", () => {
    expect(normalizeImageRef("localhost:5000/syrus-backend")).toBe("localhost:5000/syrus-backend:latest")
  })
})

describe("isSyrusManagedImageRef", () => {
  it("matches syrus-backend and syrus-local under any registry prefix", () => {
    expect(isSyrusManagedImageRef("ghcr.io/tkadauke/syrus-backend:0.1.1")).toBe(true)
    expect(isSyrusManagedImageRef("ghcr.io/somefork/syrus-local:dev-abc123")).toBe(true)
    expect(isSyrusManagedImageRef("syrus-backend:dev-abc123")).toBe(true)
    expect(isSyrusManagedImageRef("localhost:5000/syrus-backend:0.1.0")).toBe(true)
  })

  it("never matches unrelated images", () => {
    expect(isSyrusManagedImageRef("mysql:8.0")).toBe(false)
    expect(isSyrusManagedImageRef("ghcr.io/other/webapp:latest")).toBe(false)
  })

  it("requires an exact basename — my-syrus-backend is not ours", () => {
    expect(isSyrusManagedImageRef("ghcr.io/x/my-syrus-backend:1.0")).toBe(false)
    expect(isSyrusManagedImageRef("syrus-backend-fork:1.0")).toBe(false)
  })

  it("skips dangling <none> rows (not removable by ref)", () => {
    expect(isSyrusManagedImageRef("<none>:<none>")).toBe(false)
    expect(isSyrusManagedImageRef("ghcr.io/tkadauke/syrus-backend:<none>")).toBe(false)
  })
})

describe("supersededSyrusImages", () => {
  const listing = [
    "ghcr.io/tkadauke/syrus-backend:0.1.2",
    "ghcr.io/tkadauke/syrus-backend:0.1.1",
    "ghcr.io/tkadauke/syrus-backend:0.1.0",
    "ghcr.io/tkadauke/syrus-local:latest",
    "syrus-backend:dev-cafe123",
    "ghcr.io/somefork/syrus-backend:0.1.1",
    "mysql:8.0",
    "traefik:v3.1",
    "<none>:<none>"
  ]

  it("removes only same-repository siblings of the pin, keeping the pin and in-use refs", () => {
    expect(
      supersededSyrusImages(listing, {
        pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
        inUseRefs: ["ghcr.io/tkadauke/syrus-backend:0.1.2", "mysql:8.0"]
      })
    ).toEqual([
      "ghcr.io/tkadauke/syrus-backend:0.1.1",
      "ghcr.io/tkadauke/syrus-backend:0.1.0"
    ])
  })

  it("regression: never deletes a developer's locally built image in another repository", () => {
    // `syrus-backend:dev-cafe123` shares the basename but NOT the repository
    // with the pinned ghcr.io ref — the old basename-wide rule deleted it on
    // a routine desktop update.
    const removable = supersededSyrusImages(listing, {
      pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
      inUseRefs: []
    })
    expect(removable).not.toContain("syrus-backend:dev-cafe123")
    expect(removable).not.toContain("ghcr.io/somefork/syrus-backend:0.1.1")
    expect(removable).not.toContain("ghcr.io/tkadauke/syrus-local:latest")
  })

  it("does clean same-repository siblings when the pin itself is a dev/fork repository", () => {
    expect(
      supersededSyrusImages(
        ["syrus-backend:dev-cafe123", "syrus-backend:dev-old999", "ghcr.io/tkadauke/syrus-backend:0.1.2"],
        { pinnedRef: "syrus-backend:dev-cafe123", inUseRefs: [] }
      )
    ).toEqual(["syrus-backend:dev-old999"])
  })

  it("keeps a superseded image while a running container still references it", () => {
    expect(
      supersededSyrusImages(listing, {
        pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
        inUseRefs: ["ghcr.io/tkadauke/syrus-backend:0.1.1"]
      })
    ).not.toContain("ghcr.io/tkadauke/syrus-backend:0.1.1")
  })

  it("never touches non-syrus images regardless of pin", () => {
    const removable = supersededSyrusImages(listing, {
      pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
      inUseRefs: []
    })
    expect(removable).not.toContain("mysql:8.0")
    expect(removable).not.toContain("traefik:v3.1")
    expect(removable).not.toContain("<none>:<none>")
  })

  it("removes nothing without a pinned ref — no pin means no known-current image", () => {
    expect(supersededSyrusImages(listing, { pinnedRef: null, inUseRefs: [] })).toEqual([])
  })

  it("skips a dangling <none> tag even inside the pinned repository", () => {
    expect(
      supersededSyrusImages(["ghcr.io/tkadauke/syrus-backend:<none>"], {
        pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
        inUseRefs: []
      })
    ).toEqual([])
  })

  it("matches a tagless in-use ref against its :latest row", () => {
    expect(
      supersededSyrusImages(["ghcr.io/tkadauke/syrus-backend:latest"], {
        pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
        inUseRefs: ["ghcr.io/tkadauke/syrus-backend"]
      })
    ).toEqual([])
  })
})

describe("removeSupersededSyrusImages", () => {
  const dockerReplies = (replies: Record<string, string>) => {
    execFileAsyncMock.mockImplementation(async (...callArgs: unknown[]) => {
      const args = callArgs[1] as string[]
      const key = args.join(" ")
      for (const [prefix, stdout] of Object.entries(replies)) {
        if (key.startsWith(prefix)) {
          return { stdout, stderr: "" }
        }
      }
      return { stdout: "", stderr: "" }
    })
  }

  it("removes superseded refs with plain `docker image rm` (never --force) and logs sizes", async () => {
    dockerReplies({
      images: [
        "ghcr.io/tkadauke/syrus-backend:0.1.2|7.62GB",
        "ghcr.io/tkadauke/syrus-backend:0.1.1|7.61GB",
        "syrus-backend:dev-cafe123|7.60GB",
        "mysql:8.0|581MB"
      ].join("\n"),
      ps: "ghcr.io/tkadauke/syrus-backend:0.1.2\nmysql:8.0\n"
    })

    const lines: string[] = []
    const result = await removeSupersededSyrusImages({
      pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2",
      log: (line) => lines.push(line)
    })

    // Same-repository sibling only — the dev-built `syrus-backend:dev-cafe123`
    // lives in a different repository and must survive the update.
    expect(result.removed).toEqual(["ghcr.io/tkadauke/syrus-backend:0.1.1"])
    expect(result.reclaimedDisplay).toContain("GB")

    const rmCalls = execFileAsyncMock.mock.calls.filter((call) => (call[1] as string[])[0] === "image")
    expect(rmCalls).toEqual([
      ["/usr/local/bin/docker", ["image", "rm", "ghcr.io/tkadauke/syrus-backend:0.1.1"], expect.anything()]
    ])
    expect(lines.join("\n")).toContain("7.61GB")
  })

  it("ignores individual rm failures (an in-use image refuses politely) and keeps going", async () => {
    dockerReplies({
      images: [
        "ghcr.io/tkadauke/syrus-backend:0.1.2|7.62GB",
        "ghcr.io/tkadauke/syrus-backend:0.1.1|7.61GB",
        "ghcr.io/tkadauke/syrus-backend:0.1.0|7.60GB"
      ].join("\n"),
      ps: "",
      "image rm ghcr.io/tkadauke/syrus-backend:0.1.1": "" // overridden below
    })
    const base = execFileAsyncMock.getMockImplementation()!
    execFileAsyncMock.mockImplementation(async (...callArgs: unknown[]) => {
      const args = callArgs[1] as string[]
      if (args.join(" ") === "image rm ghcr.io/tkadauke/syrus-backend:0.1.1") {
        throw new Error("conflict: image is being used by stopped container deadbeef")
      }
      return base(...callArgs)
    })

    const result = await removeSupersededSyrusImages({ pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2" })
    expect(result.removed).toEqual(["ghcr.io/tkadauke/syrus-backend:0.1.0"])
  })

  it("does nothing without a pinned ref (first-install guard)", async () => {
    const result = await removeSupersededSyrusImages({ pinnedRef: null })
    expect(result).toEqual({ removed: [], reclaimedDisplay: null })
    expect(execFileAsyncMock).not.toHaveBeenCalled()
  })

  it("is best-effort: a docker listing failure yields an empty result, not a throw", async () => {
    execFileAsyncMock.mockRejectedValue(new Error("Cannot connect to the Docker daemon"))
    await expect(
      removeSupersededSyrusImages({ pinnedRef: "ghcr.io/tkadauke/syrus-backend:0.1.2" })
    ).resolves.toEqual({ removed: [], reclaimedDisplay: null })
  })
})
