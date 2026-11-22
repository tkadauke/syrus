import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("../api/browserErrors", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api/browserErrors")>()
  return { ...original, recordBrowserError: vi.fn().mockResolvedValue({ id: 1, fingerprint: "fp", occurrence_count: 1 }) }
})

import { recordBrowserError } from "../api/browserErrors"
import { ApiError } from "../api/client"
import { isReportableHandledError, reportHandledError, sanitizeHandledErrorContext } from "./handledErrorReporting"

const mockRecordBrowserError = vi.mocked(recordBrowserError)

afterEach(() => {
  mockRecordBrowserError.mockReset().mockResolvedValue({ id: 1, fingerprint: "fp", occurrence_count: 1 })
})

describe("handled error reporting", () => {
  it("reports a scrubbed error through the browser-error pipeline with safe operation context", () => {
    const error = new Error("upload failed https://example.test/file?token=secret")
    error.stack = "Error at /chats/shared/private-token"

    expect(
      reportHandledError(error, {
        surface: "screenshot_annotations",
        operation: "upload",
        stage: "serialize",
        recoverability: "retryable",
        diagnostics: { attempt: 2, provider: "canvas", filename: "private.png", body: { secret: true }, transport: "bad value with text" }
      })
    ).toBe(true)

    expect(mockRecordBrowserError).toHaveBeenCalledTimes(1)
    const payload = mockRecordBrowserError.mock.calls[0][0]
    expect(payload.message).toContain("?[FILTERED]")
    expect(payload.stack).toContain("/chats/shared/[FILTERED]")
    expect(payload.metadata.handled_error).toEqual({
      surface: "screenshot_annotations",
      operation: "upload",
      stage: "serialize",
      recoverability: "retryable",
      diagnostics: { attempt: 2, provider: "canvas" }
    })
    expect(JSON.stringify(payload)).not.toContain("private.png")
    expect(payload.correlation_id).toBeTruthy()
    expect(payload.recoverable).toBe(true)
  })

  it("strips arbitrary names, nested values, URLs, and text diagnostics", () => {
    expect(
      sanitizeHandledErrorContext({
        surface: "Private document text",
        operation: "https://example.test/private",
        stage: "upload file.png",
        recoverability: "unknown",
        diagnostics: {
          count: 3,
          status_code: 500,
          provider: "safe_provider",
          transport: "https://secret.test",
          url: "https://secret.test",
          blob: new Blob(["secret"])
        }
      })
    ).toEqual({
      surface: "unknown_surface",
      operation: "unknown_operation",
      stage: "unknown_stage",
      recoverability: "unknown",
      diagnostics: { count: 3, status_code: 500, provider: "safe_provider" }
    })
  })

  it("allows only bounded image replacement diagnostics", () => {
    expect(
      sanitizeHandledErrorContext({
        surface: "chat_composer",
        operation: "replace_attachment",
        stage: "upload",
        recoverability: "retryable",
        diagnostics: {
          mime_category: "image",
          width: 1280,
          height: 720,
          byte_size_bucket: "under_1mb",
          filename: "private.png",
          annotation_text: "secret",
          data_url: "data:image/png;base64,secret"
        }
      }).diagnostics
    ).toEqual({ mime_category: "image", width: 1280, height: 720, byte_size_bucket: "under_1mb" })
  })

  it("excludes cancellation and deliberate control-flow outcomes", () => {
    expect(isReportableHandledError(new DOMException("aborted", "AbortError"))).toBe(false)
    expect(isReportableHandledError(new ApiError("validation", { status: 422 }))).toBe(false)
    expect(
      reportHandledError(new Error("declined"), {
        surface: "permissions",
        operation: "grant",
        stage: "confirm",
        recoverability: "non_retryable",
        expectedOutcome: "user_declined"
      })
    ).toBe(false)
    expect(mockRecordBrowserError).not.toHaveBeenCalled()
  })

  it("contains synchronous and asynchronous telemetry failures", async () => {
    mockRecordBrowserError.mockRejectedValueOnce(new Error("telemetry failed"))
    expect(
      reportHandledError(new Error("product failed"), {
        surface: "test_surface",
        operation: "save",
        stage: "request",
        recoverability: "retryable"
      })
    ).toBe(true)
    await Promise.resolve()

    mockRecordBrowserError.mockImplementationOnce(() => {
      throw new Error("synchronous telemetry failure")
    })
    expect(() =>
      reportHandledError(new Error("another failure"), {
        surface: "test_surface",
        operation: "save",
        stage: "request",
        recoverability: "retryable"
      })
    ).not.toThrow()
  })

  it("prevents recursive reporting while telemetry submission is active", () => {
    mockRecordBrowserError.mockImplementationOnce(() => {
      reportHandledError(new Error("telemetry itself failed"), {
        surface: "telemetry",
        operation: "submit",
        stage: "request",
        recoverability: "unknown"
      })
      return Promise.reject(new Error("submission failed"))
    })

    reportHandledError(new Error("product failed"), {
      surface: "job_editor",
      operation: "save",
      stage: "request",
      recoverability: "retryable"
    })

    expect(mockRecordBrowserError).toHaveBeenCalledTimes(1)
  })
})
