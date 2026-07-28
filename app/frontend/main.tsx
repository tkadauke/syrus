import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { BrowserRouter } from "react-router-dom"
import { I18nextProvider } from "react-i18next"
import { App } from "./routes/App"
import { AppErrorBoundary } from "./components/AppErrorBoundary"
import i18n from "./i18n"
import { initErrorRingBuffer } from "./lib/errorRingBuffer"

initErrorRingBuffer()

const root = document.getElementById("syrus-spa-root")
const queryClient = new QueryClient()

if (root) {
  createRoot(root).render(
    <StrictMode>
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={queryClient}>
          <BrowserRouter>
            <AppErrorBoundary>
              <App />
            </AppErrorBoundary>
          </BrowserRouter>
        </QueryClientProvider>
      </I18nextProvider>
    </StrictMode>
  )
}
