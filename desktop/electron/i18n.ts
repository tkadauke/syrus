import { app } from "electron"
import { normalizeLocale, translate } from "./i18nCatalog.js"

export const appLocale = () => normalizeLocale(app.getLocale())

export const t = (key: string, values: Record<string, string | number | null | undefined> = {}) =>
  translate(appLocale(), key, values)
