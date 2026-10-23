export { messages, normalizeLocale, supportedLocales, translate } from "../electron/i18nCatalog"
export type { Locale } from "../electron/i18nCatalog"

import { translate } from "../electron/i18nCatalog"

const rendererLocale = () => (typeof navigator === "undefined" ? "en" : navigator.language)

export function t(key: string, values: Record<string, string | number | null | undefined> = {}) {
  return translate(rendererLocale(), key, values)
}
