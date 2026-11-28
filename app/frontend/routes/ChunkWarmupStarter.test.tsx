import { render } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { StartupRenderMarker } from "../lib/StartupRenderMarker"

const startChunkWarmup = vi.fn()
const readInitialBootstrap = vi.fn()

vi.mock("../lib/chunkWarmup", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../lib/chunkWarmup")>()),
  startChunkWarmup: (...args: unknown[]) => startChunkWarmup(...args)
}))
vi.mock("../api/bootstrap", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../api/bootstrap")>()),
  readInitialBootstrap: () => readInitialBootstrap()
}))

const { ChunkWarmupStarter } = await import("./ChunkWarmupStarter")

afterEach(() => {
  vi.unstubAllEnvs()
  vi.clearAllMocks()
  delete window.SyrusStartupDiagnostics
})

describe("ChunkWarmupStarter", () => {
  it("starts warm-up only after the startup marker records react_commit", () => {
    const order: string[] = []
    window.SyrusStartupDiagnostics = { mark: (milestone: string) => order.push(milestone) }
    readInitialBootstrap.mockReturnValue({ current_user: { admin: true } })
    startChunkWarmup.mockImplementation(() => order.push("warmup"))

    render(
      <>
        <StartupRenderMarker />
        <ChunkWarmupStarter />
      </>
    )

    expect(order.slice(0, 2)).toEqual(["react_commit", "warmup"])
    expect(startChunkWarmup).toHaveBeenCalledWith({ skipGroups: [] })
  })

  it("leaves admin pages cold for non-admins", () => {
    readInitialBootstrap.mockReturnValue({ current_user: { admin: false } })

    render(<ChunkWarmupStarter />)

    expect(startChunkWarmup).toHaveBeenCalledWith({ skipGroups: ["admin"] })
  })

  it("warms nothing for a signed-out visitor", () => {
    readInitialBootstrap.mockReturnValue({ current_user: null })

    render(<ChunkWarmupStarter />)

    expect(startChunkWarmup).not.toHaveBeenCalled()
  })

  it("skips warm-up against the Vite dev server", () => {
    vi.stubEnv("MODE", "development")
    readInitialBootstrap.mockReturnValue({ current_user: { admin: true } })

    render(<ChunkWarmupStarter />)

    expect(startChunkWarmup).not.toHaveBeenCalled()
  })
})
