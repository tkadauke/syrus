import { normalizeLocale, translate } from "./i18nCatalog.js"

export const createElectronI18n = (getLocale: () => string) => {
  const appLocale = () => normalizeLocale(getLocale())
  const t = (key: string, values: Record<string, string | number | null | undefined> = {}) =>
    translate(appLocale(), key, values)

  return { appLocale, t }
}
