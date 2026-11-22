import { afterEach, describe, expect, it, vi } from "vitest"
import { reportHandledError } from "../../lib/handledErrorReporting"
import { attachMediaLibraryImage } from "./attachMediaLibraryImage"

vi.mock("../../lib/handledErrorReporting", () => ({ reportHandledError: vi.fn() }))

describe("attachMediaLibraryImage", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("preserves the fetch-failed result and reports the local file-fetch stage", async () => {
    const failure = new TypeError("network unavailable")
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(failure))

    await expect(
      attachMediaLibraryImage({
        chatId: "7",
        url: "https://example.test/private/image.png",
        name: "image.png",
        mimeType: "image/png"
      })
    ).resolves.toEqual({ ok: false, reason: "fetch_failed" })
    expect(reportHandledError).toHaveBeenCalledWith(failure, {
      surface: "chat_media_library",
      operation: "attach_image",
      stage: "fetch_file",
      recoverability: "retryable"
    })
  })
})
