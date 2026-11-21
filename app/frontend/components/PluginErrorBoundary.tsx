import { Component, Suspense, type ComponentType, type ErrorInfo, type ReactNode } from "react"
import { buildBrowserErrorPayload, recordBrowserError } from "../api/browserErrors"
import { computeBrowserErrorFingerprint } from "../lib/browserErrorFingerprint"
import { useT } from "../hooks/useT"
import { Button } from "./Button"

function PluginErrorFallback({ pluginName }: { pluginName: string }) {
  const { t } = useT("common")
  return (
    <div className="rounded border border-danger-border bg-danger-bg p-3 text-sm text-danger-text" role="alert">
      <p className="font-medium">{t("plugin_error.heading", { plugin: pluginName })}</p>
      <Button className="mt-2" size="sm" variant="secondary" onClick={() => window.location.reload()}>
        {t("plugin_error.reload")}
      </Button>
    </div>
  )
}

function PluginLoadingFallback() {
  const { t } = useT("common")
  return (
    // aria-live, not role="status": the plugin rendered here often owns that
    // role itself, and claiming it while loading made queries for the
    // plugin's own status message find this placeholder instead.
    <p aria-busy="true" aria-live="polite" className="text-sm text-text-muted" data-testid="plugin-loading">
      {t("loading")}
    </p>
  )
}

type State = { failed: boolean }

export class PluginErrorBoundary extends Component<{ children: ReactNode; pluginName: string }, State> {
  state: State = { failed: false }

  static getDerivedStateFromError(): State {
    return { failed: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    void recordBrowserError(
      buildBrowserErrorPayload(error, {
        boundary: `plugin:${this.props.pluginName}`,
        componentStack: info.componentStack ?? "",
        fingerprint: computeBrowserErrorFingerprint(error)
      })
    ).catch(() => {
      // Plugin isolation must remain usable when diagnostic delivery fails.
    })
  }

  // A plugin component that suspends (a lazy chunk, a suspense query) must get
  // a loading state, not an error. Without a Suspense boundary here, suspending
  // during a synchronous update -- picking a Rails artifact in the Review tab's
  // selector -- threw React #426 into this error boundary, and the plugin showed
  // "could not be displayed" instead of rendering once loaded.
  render() {
    if (this.state.failed) return <PluginErrorFallback pluginName={this.props.pluginName} />

    return <Suspense fallback={<PluginLoadingFallback />}>{this.props.children}</Suspense>
  }
}

const wrappedComponents = new WeakMap<ComponentType<object>, Map<string, ComponentType<object>>>()

export function withPluginErrorBoundary<Props extends object>(pluginName: string, Wrapped: ComponentType<Props>): ComponentType<Props> {
  const cached = wrappedComponents.get(Wrapped as ComponentType<object>)?.get(pluginName)
  if (cached) return cached as ComponentType<Props>
  function BoundaryWrappedComponent(props: Props) {
    return (
      <PluginErrorBoundary pluginName={pluginName}>
        <Wrapped {...props} />
      </PluginErrorBoundary>
    )
  }
  const byPlugin = wrappedComponents.get(Wrapped as ComponentType<object>) ?? new Map<string, ComponentType<object>>()
  byPlugin.set(pluginName, BoundaryWrappedComponent as ComponentType<object>)
  wrappedComponents.set(Wrapped as ComponentType<object>, byPlugin)
  return BoundaryWrappedComponent
}

function PluginRenderer({ render }: { render: () => ReactNode }) {
  return render()
}

export function PluginRenderBoundary({ pluginName, render }: { pluginName: string; render: () => ReactNode }) {
  return (
    <PluginErrorBoundary pluginName={pluginName}>
      <PluginRenderer render={render} />
    </PluginErrorBoundary>
  )
}
