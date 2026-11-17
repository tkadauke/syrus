import { readInitialBootstrap, type ExternalPluginFrontend } from "./api/bootstrap"

type ModuleImporter = (url: string) => Promise<unknown>

const importModule: ModuleImporter = (url) => import(/* @vite-ignore */ url)

export async function loadExternalPluginFrontends(
  entries: readonly ExternalPluginFrontend[] = readInitialBootstrap()?.app.external_plugin_frontends ?? [],
  importer: ModuleImporter = importModule
) {
  entries.forEach(loadStylesheet)

  await Promise.all(
    entries.map(async (entry) => {
      try {
        await importer(entry.bundle_url)
      } catch (error) {
        console.error(`[plugin frontend] Failed to load ${entry.name}`, error)
      }
    })
  )
}

function loadStylesheet(entry: ExternalPluginFrontend) {
  const alreadyLoaded = Array.from(document.querySelectorAll<HTMLLinkElement>("link[data-syrus-plugin-css]")).some(
    (link) => link.dataset.syrusPluginCss === entry.name
  )
  if (!entry.css_url || alreadyLoaded) return

  const link = document.createElement("link")
  link.rel = "stylesheet"
  link.href = entry.css_url
  link.dataset.syrusPluginCss = entry.name
  document.head.append(link)
}
