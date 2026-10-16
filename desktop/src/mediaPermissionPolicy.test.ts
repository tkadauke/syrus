import { describe, expect, it } from "vitest"

import { isPermissionCheckAllowed, isPermissionRequestAllowed } from "../electron/mediaPermissionPolicy"

const trustedWebContents = {}
const requestContext = {
  permission: "media",
  webContents: trustedWebContents,
  trustedWebContents,
  requestingUrl: "https://syrus.example/chats/1",
  expectedOrigin: "https://syrus.example",
  isMainFrame: true,
  mediaTypes: ["audio"]
}

describe("desktop media permission policy", () => {
  it("allows an audio-only request from the trusted instance top frame", () => {
    expect(isPermissionRequestAllowed(requestContext)).toBe(true)
    expect(isPermissionCheckAllowed({ ...requestContext, mediaType: "audio" })).toBe(true)
  })

  it.each([
    { label: "video", mediaTypes: ["video"] },
    { label: "audio and video", mediaTypes: ["audio", "video"] },
    { label: "missing media types", mediaTypes: undefined },
    { label: "empty media types", mediaTypes: [] },
    { label: "unknown media type", mediaTypes: ["unknown"] }
  ])("denies a media request with $label", ({ mediaTypes }) => {
    expect(isPermissionRequestAllowed({ ...requestContext, mediaTypes })).toBe(false)
  })

  it.each(["video", "unknown", undefined])("denies a media check for %s", (mediaType) => {
    expect(isPermissionCheckAllowed({ ...requestContext, mediaType })).toBe(false)
  })

  it.each([
    { label: "foreign origin", override: { requestingUrl: "https://attacker.example" } },
    { label: "subframe", override: { isMainFrame: false } },
    { label: "other web contents", override: { webContents: {} } },
    { label: "missing trusted web contents", override: { trustedWebContents: null } },
    { label: "unrelated permission", override: { permission: "geolocation" } }
  ])("denies a request from a $label", ({ override }) => {
    expect(isPermissionRequestAllowed({ ...requestContext, ...override })).toBe(false)
    expect(isPermissionCheckAllowed({ ...requestContext, mediaType: "audio", ...override })).toBe(false)
  })

  it("allows only the two non-media permissions needed by the web app", () => {
    expect(isPermissionRequestAllowed({ ...requestContext, permission: "display-capture", mediaTypes: undefined })).toBe(true)
    expect(
      isPermissionRequestAllowed({ ...requestContext, permission: "clipboard-sanitized-write", mediaTypes: undefined })
    ).toBe(true)
  })
})
