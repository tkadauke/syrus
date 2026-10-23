import { app } from "electron"

import { normalizeLocale, translate } from "./i18nCatalog.js"

export const appLocale = () => normalizeLocale(app.getLocale())

export function t(key: string, values: Record<string, string | number | null | undefined> = {}) {
  return translate(appLocale(), key, values)
}
