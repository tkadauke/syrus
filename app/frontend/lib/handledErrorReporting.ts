import { isCancelledError } from "@tanstack/react-query"
import { buildBrowserErrorPayload, recordBrowserError, type HandledErrorMetadata } from "../api/browserErrors"
import { ApiError } from "../api/client"
import { computeBrowserErrorFingerprint } from "./browserErrorFingerprint"
import { newCorrelationId } from "./recoverableErrorDiagnostics"

export type HandledErrorContext = {
  surface: string
  operation: string
  stage: string
  recoverability: HandledErrorMetadata["recoverability"]
  expectedOutcome?: "validation" | "authorization_prompt" | "user_declined"
  diagnostics?: Record<string, unknown>
}

const SAFE_DIAGNOSTIC_KEYS = new Set([
  "attempt", "byte_size_bucket", "count", "duration_ms", "height", "item_count",
  "mime_category", "provider", "status_code", "transport", "width"
])
const STABLE_NAME = /^[a-z][a-z0-9_.:-]{0,99}$/
const explicitlyReported = new WeakSet<object>()
let submissionDepth = 0

export function reportHandledError(error: unknown, context: HandledErrorContext): boolean {
  if (!isReportableHandledError(error, context) || submissionDepth > 0) return false

  const normalized = normalizeError(error)
  if (isObject(error)) explicitlyReported.add(error)

  try {
    submissionDepth += 1
    const payload = buildBrowserErrorPayload(normalized, {
      boundary: "handled_operation",
      correlationId: newCorrelationId(),
      fingerprint: computeBrowserErrorFingerprint(normalized),
      recoverable: true,
      handledError: sanitizeHandledErrorContext(context)
    })
    void Promise.resolve(recordBrowserError(payload)).catch(() => undefined)
    return true
  } catch {
    return false
  } finally {
    submissionDepth -= 1
  }
}

export function isReportableHandledError(error: unknown, context?: Pick<HandledErrorContext, "expectedOutcome">): boolean {
  if (context?.expectedOutcome) return false
  if (isCancelledError(error)) return false
  if (error instanceof DOMException && error.name === "AbortError") return false
  if (error instanceof Error && error.name === "AbortError") return false
  if (error instanceof ApiError && [401, 403, 422].includes(error.status)) return false
  return true
}

export function wasExplicitlyReported(error: unknown): boolean {
  return isObject(error) && explicitlyReported.has(error)
}

export function sanitizeHandledErrorContext(context: HandledErrorContext): HandledErrorMetadata {
  return {
    surface: stableName(context.surface, "unknown_surface"),
    operation: stableName(context.operation, "unknown_operation"),
    stage: stableName(context.stage, "unknown_stage"),
    recoverability: context.recoverability,
    ...(context.diagnostics ? { diagnostics: safeDiagnostics(context.diagnostics) } : {})
  }
}

function safeDiagnostics(input: Record<string, unknown>): Record<string, boolean | number | string> {
  const output: Record<string, boolean | number | string> = {}
  for (const [key, value] of Object.entries(input)) {
    if (!SAFE_DIAGNOSTIC_KEYS.has(key)) continue
    if (typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value))) output[key] = value
    if (typeof value === "string" && STABLE_NAME.test(value)) output[key] = value
  }
  return output
}

function stableName(value: string, fallback: string): string {
  return STABLE_NAME.test(value) ? value : fallback
}

function normalizeError(error: unknown): Error {
  if (!(error instanceof Error)) return new Error("Non-Error rejection")
  return error
}

function isObject(value: unknown): value is object {
  return (typeof value === "object" && value !== null) || typeof value === "function"
}
