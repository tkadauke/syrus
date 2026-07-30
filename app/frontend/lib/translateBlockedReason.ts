import type { TFunction } from "i18next"

export type BlockedReason = {
  key: string
  params?: Record<string, string | number>
}

export function translateBlockedReason(
  reason: BlockedReason | string | null | undefined,
  t: TFunction
): string {
  if (!reason) return ""
  if (typeof reason === "string") return reason
  return t(`common:blocked_reasons.${reason.key}`, reason.params ?? {})
}
