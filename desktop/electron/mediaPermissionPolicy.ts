type PermissionContext = {
  permission: string
  webContents: unknown | null
  trustedWebContents: unknown | null
  requestingUrl: string
  expectedOrigin: string | null
  isMainFrame: boolean
}

export type PermissionRequestContext = PermissionContext & {
  mediaTypes?: readonly string[]
}

export type PermissionCheckContext = PermissionContext & {
  mediaType?: string
}

const ALLOWED_PERMISSIONS = new Set(["media", "display-capture", "clipboard-sanitized-write"])

const matchesOrigin = (url: string, expectedOrigin: string | null): boolean => {
  if (!expectedOrigin) return false

  try {
    return new URL(url).origin === expectedOrigin
  } catch {
    return false
  }
}

const hasTrustedCaller = ({
  permission,
  webContents,
  trustedWebContents,
  requestingUrl,
  expectedOrigin,
  isMainFrame
}: PermissionContext): boolean =>
  trustedWebContents !== null &&
  webContents === trustedWebContents &&
  ALLOWED_PERMISSIONS.has(permission) &&
  isMainFrame &&
  matchesOrigin(requestingUrl, expectedOrigin)

export const isPermissionRequestAllowed = (context: PermissionRequestContext): boolean => {
  if (!hasTrustedCaller(context)) return false
  if (context.permission !== "media") return true

  return context.mediaTypes?.length === 1 && context.mediaTypes[0] === "audio"
}

export const isPermissionCheckAllowed = (context: PermissionCheckContext): boolean => {
  if (!hasTrustedCaller(context)) return false
  if (context.permission !== "media") return true

  return context.mediaType === "audio"
}
