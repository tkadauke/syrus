import { getAppLocale } from "./electronApp.js"
import { normalizeLocale, translate } from "./i18nCatalog.js"

export const appLocale = () => normalizeLocale(getAppLocale())

export function t(key: string, values: Record<string, string | number | null | undefined> = {}) {
  return translate(appLocale(), key, values)
}
