import { render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { RouteErrorBoundary } from "../components/RouteErrorBoundary"
import { ChunkWarmupQueue, type ChunkWarmupEnvironment } from "../lib/chunkWarmup"
import { lazyRoute, preloadLazyRouteElement, RouteSuspense } from "./lazyRoute"

afterEach(() => vi.restoreAllMocks())

function immediateEnvironment(): ChunkWarmupEnvironment {
  return {
    scheduleIdle: (callback) => setTimeout(callback, 0),
    isHidden: () => false,
    onVisible: () => undefined,
    connection: () => undefined
  }
}

function Wrapper({ children }: { children: React.ReactNode }) {
  return <section>{children}</section>
}

describe("lazyRoute", () => {
  it("shows a stable loading state until the route chunk arrives", async () => {
    let resolveModule!: (module: { Page: () => JSX.Element }) => void
    const Page = lazyRoute(() => new Promise<{ Page: () => JSX.Element }>((resolve) => (resolveModule = resolve)), "Page")

    render(
      <RouteSuspense>
        <Page />
      </RouteSuspense>
    )

    expect(screen.getByRole("status")).toHaveTextContent("Loading...")
    resolveModule({ Page: () => <main>Loaded page</main> })
    expect(await screen.findByText("Loaded page")).toBeInTheDocument()
  })

  it("keeps the loading state while stale-chunk recovery reloads the page", async () => {
    // staleChunkRecovery suppresses the first failure per revision and reloads,
    // which resolves Vite's preload wrapper with no module.
    const Page = lazyRoute(async () => undefined as unknown as { Page: () => JSX.Element }, "Page")

    render(
      <RouteErrorBoundary>
        <RouteSuspense>
          <Page />
        </RouteSuspense>
      </RouteErrorBoundary>
    )

    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(screen.getByRole("status")).toHaveTextContent("Loading...")
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("shows the route error boundary's reload action when a chunk cannot load", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined)
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify({ id: 1 }), { status: 200, headers: { "Content-Type": "application/json" } }))
    const Page = lazyRoute(() => Promise.reject<{ Page: () => JSX.Element }>(new Error("Failed to fetch dynamically imported module")), "Page")

    render(
      <RouteErrorBoundary>
        <RouteSuspense>
          <Page />
        </RouteSuspense>
      </RouteErrorBoundary>
    )

    expect(await screen.findByText("Failed to fetch dynamically imported module")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Reload page" })).toBeInTheDocument()
  })

  it("reuses the warmed chunk when the route is navigated to after warm-up", async () => {
    const queue = new ChunkWarmupQueue(immediateEnvironment())
    const load = vi.fn(async () => ({ Page: () => <main>Warm page</main> }))
    const Page = lazyRoute(queue.register("page", load, { priority: 0 }), "Page")

    queue.start()
    await waitFor(() => expect(queue.isLoaded("page")).toBe(true))

    render(
      <RouteSuspense>
        <Page />
      </RouteSuspense>
    )

    expect(await screen.findByText("Warm page")).toBeInTheDocument()
    expect(load).toHaveBeenCalledTimes(1)
  })

  it("preloads the lazy route inside a layout wrapper and ignores eager elements", async () => {
    const load = vi.fn(async () => ({ Page: () => <main>Page</main> }))
    const Page = lazyRoute(load, "Page")

    expect(preloadLazyRouteElement(<main>Eager</main>)).toBeUndefined()
    await preloadLazyRouteElement(
      <Wrapper>
        <Page />
      </Wrapper>
    )

    expect(load).toHaveBeenCalledTimes(1)
  })
})
