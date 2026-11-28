import { MutationCache, QueryCache, QueryClient, type QueryClientConfig } from "@tanstack/react-query"
import { reportHandledError, wasExplicitlyReported, type HandledErrorContext } from "./lib/handledErrorReporting"
import { appUpdateBlocksRetries } from "./lib/appUpdate"

export const queryClientConfig = {
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
      retry: (failureCount: number) => !appUpdateBlocksRetries() && failureCount < 1
    }
  }
} satisfies QueryClientConfig

export function createQueryClient() {
  return new QueryClient({
    ...queryClientConfig,
    queryCache: new QueryCache({
      onError: (error, query) => scheduleTerminalReport(error, telemetryContext(query.meta, "query"))
    }),
    mutationCache: new MutationCache({
      onError: (error, _variables, _context, mutation) => scheduleTerminalReport(error, telemetryContext(mutation.meta, "mutation"))
    })
  })
}

function scheduleTerminalReport(error: unknown, context: HandledErrorContext) {
  window.setTimeout(() => {
    if (!wasExplicitlyReported(error)) reportHandledError(error, context)
  }, 0)
}

function telemetryContext(meta: Record<string, unknown> | undefined, operation: "query" | "mutation"): HandledErrorContext {
  const candidate = meta?.handledError
  if (isHandledErrorContext(candidate)) return candidate
  return { surface: "react_query", operation, stage: "terminal", recoverability: "unknown" }
}

function isHandledErrorContext(value: unknown): value is HandledErrorContext {
  if (!value || typeof value !== "object") return false
  const candidate = value as Partial<HandledErrorContext>
  return (
    typeof candidate.surface === "string" &&
    typeof candidate.operation === "string" &&
    typeof candidate.stage === "string" &&
    ["retryable", "non_retryable", "unknown"].includes(candidate.recoverability || "")
  )
}
