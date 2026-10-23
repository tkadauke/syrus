export { messages, normalizeLocale, supportedLocales, translate } from "../electron/i18nCatalog"
export type { DesktopMessageKey, Locale } from "../electron/i18nCatalog"

import { normalizeLocale, translate } from "../electron/i18nCatalog"

export function currentLocale() {
  return normalizeLocale(navigator.language)
}

export function t(key: string, values: Record<string, string | number | null | undefined> = {}) {
  return translate(currentLocale(), key, values)
}
