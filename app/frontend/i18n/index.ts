import i18n, { type BackendModule, type ReadCallback, type ResourceLanguage } from "i18next"
import { initReactI18next } from "react-i18next"

import { readInitialBootstrap } from "../api/bootstrap"

type LocaleModule = { default: ResourceLanguage }
type LocaleLoader = () => Promise<LocaleModule>

export const supportedLocales = ["en", "de", "la"] as const
export type SupportedLocale = (typeof supportedLocales)[number]
export const coreNamespaces = ["common", "nav", "jobs", "epics", "dashboard", "chat", "settings", "admin", "auth", "landing", "tours"] as const

const coreLocaleModules = import.meta.glob<LocaleModule>("./locales/*/*.json")
const pluginLocaleModules = import.meta.glob<LocaleModule>("../../../plugins/*/app/frontend/i18n/locales/*/*.json")
const localeLoaders = new Map<string, LocaleLoader>()
const pluginNamespaces = new Map<string, Set<string>>()

for (const [path, loader] of Object.entries(coreLocaleModules)) {
  const match = path.match(/\/locales\/([^/]+)\/([^/.]+)\.json$/)
  if (match) localeLoaders.set(`${match[1]}:${match[2]}`, loader)
}

for (const [path, loader] of Object.entries(pluginLocaleModules)) {
  const match = path.match(/\/plugins\/([^/]+)\/app\/frontend\/i18n\/locales\/([^/]+)\/([^/.]+)\.json$/)
  if (!match) continue

  const [, plugin, locale, namespace] = match
  localeLoaders.set(`${locale}:${namespace}`, loader)
  const namespaces = pluginNamespaces.get(plugin) ?? new Set<string>()
  namespaces.add(namespace)
  pluginNamespaces.set(plugin, namespaces)
}

const localeBackend: BackendModule = {
  type: "backend",
  init: () => undefined,
  read(language: string, namespace: string, callback: ReadCallback) {
    const loader = localeLoaders.get(`${language}:${namespace}`)
    if (!loader) {
      callback(new Error(`No locale module for ${language}:${namespace}`), false)
      return
    }

    void loader().then(
      (module) => callback(null, module.default),
      (error: unknown) => callback(error instanceof Error ? error : new Error(String(error)), false)
    )
  }
}

const bootstrap = readInitialBootstrap()
const storedLocale = bootstrap?.current_user?.locale
const browserLocale = navigator.language?.split("-")[0]
const detectedLocale = storedLocale ?? (supportedLocales.includes(browserLocale as SupportedLocale) ? browserLocale : "en")

export const i18nReady = i18n
  .use(localeBackend)
  .use(initReactI18next)
  .init({
    lng: detectedLocale,
    fallbackLng: "en",
    supportedLngs: [...supportedLocales],
    load: "languageOnly",
    defaultNS: "common",
    ns: [...coreNamespaces],
    interpolation: { escapeValue: false },
    react: { useSuspense: true }
  })

/** Load a plugin's translations at the same lazy boundary as its UI module. */
export async function loadPluginLocales(plugin: string) {
  await i18nReady
  const namespaces = [...(pluginNamespaces.get(plugin) ?? [])]
  if (namespaces.length > 0) await i18n.loadNamespaces(namespaces)
}

export async function loadPluginModule<T>(plugin: string, loader: () => Promise<T>) {
  const [, module] = await Promise.all([loadPluginLocales(plugin), loader()])
  return module
}

export function pluginNamespacesFor(plugin: string | null | undefined) {
  return plugin ? [...(pluginNamespaces.get(plugin) ?? [])] : []
}

export default i18n
