import { isValidElement, lazy, Suspense, type ComponentType, type LazyExoticComponent, type ReactNode } from "react"
import { useT } from "../hooks/useT"

type AnyComponent = ComponentType<any>

const routeLoaders = new WeakMap<object, () => Promise<unknown>>()

/**
 * A route component loaded from its own chunk through a shared warmable
 * loader (routes/routeChunks.ts), so React.lazy, the boot-time preload and
 * background warm-up all reuse one request.
 *
 * After a deploy a tab may ask for a chunk hash the server no longer has.
 * staleChunkRecovery answers the first such failure by reloading the page and
 * suppressing the error, which resolves the import with no module. The route
 * then keeps showing its loading state until the reload lands instead of
 * rendering nothing. A failure it does not suppress (a second one in the same
 * revision) rejects into the route error boundary, which offers a reload.
 */
export function lazyRoute<M, K extends keyof M>(load: () => Promise<M>, exportName: K): LazyExoticComponent<M[K] & AnyComponent> {
  const component = lazy(async () => {
    const module = await load()
    if (module == null) return new Promise<never>(() => undefined)
    return { default: module[exportName] as M[K] & AnyComponent }
  })
  routeLoaders.set(component, load)
  return component
}

/**
 * Starts the chunk load for the first lazy route component found in a route
 * element (the element itself, or one wrapped by a layout such as the
 * settings section). Returns undefined when the element is eager.
 */
export function preloadLazyRouteElement(element: ReactNode): Promise<unknown> | undefined {
  if (!isValidElement(element)) return undefined
  const load = routeLoaders.get(element.type as object)
  if (load) return load()
  const children = (element.props as { children?: ReactNode }).children
  const candidates = Array.isArray(children) ? children : [children]
  for (const child of candidates) {
    const pending = preloadLazyRouteElement(child)
    if (pending) return pending
  }
  return undefined
}

export function RouteLoading() {
  const { t } = useT("common")
  return (
    <div aria-busy="true" className="min-h-full p-6 text-sm text-text-muted" role="status">
      {t("loading")}
    </div>
  )
}

/** Suspense boundary for a lazy route with a stable loading state. */
export function RouteSuspense({ children }: { children: ReactNode }) {
  return <Suspense fallback={<RouteLoading />}>{children}</Suspense>
}
