import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { QueryClientProvider } from "@tanstack/react-query"
import { BrowserRouter } from "react-router-dom"
import { I18nextProvider } from "react-i18next"
import { App } from "./routes/App"
import { AppErrorBoundary } from "./components/AppErrorBoundary"
import i18n from "./i18n"
import { I18nStartupGate } from "./i18n/I18nStartupGate"
import { initErrorRingBuffer } from "./lib/errorRingBuffer"
import { startBrowserPerformanceObservers } from "./lib/performanceTrace"
import { markStartupMilestone, reportStartupFailure } from "./lib/startupDiagnostics"
import { installStaleChunkRecovery } from "./lib/staleChunkRecovery"
import { configureExcalidrawAssets } from "./lib/excalidrawAssets"
import { StartupRenderMarker } from "./lib/StartupRenderMarker"
import { createQueryClient } from "./queryClient"
import "./builtInPluginContributions"
import { loadExternalPluginFrontends } from "./externalPluginFrontends"

installStaleChunkRecovery()
configureExcalidrawAssets()
initErrorRingBuffer()
startBrowserPerformanceObservers()
markStartupMilestone("react_module_evaluated")

const root = document.getElementById("syrus-spa-root")
const queryClient = createQueryClient()

async function renderApplication() {
  try {
    await loadExternalPluginFrontends()
    if (!root) {
      reportStartupFailure("root_mount", new Error("SPA root element is missing"))
      return
    }

    createRoot(root).render(
      <StrictMode>
        <I18nextProvider i18n={i18n}>
          <I18nStartupGate>
            <QueryClientProvider client={queryClient}>
              <BrowserRouter>
                <AppErrorBoundary>
                  <StartupRenderMarker />
                  <App />
                </AppErrorBoundary>
              </BrowserRouter>
            </QueryClientProvider>
          </I18nStartupGate>
        </I18nextProvider>
      </StrictMode>
    )
  } catch (error) {
    reportStartupFailure("root_mount", error)
  }
}

void renderApplication()
