import type { Metadata } from "next"
import { localizedMetadata } from "@/lib/metadata"
import { Nav } from "@/components/nav"
import { Footer } from "@/components/footer"
import { PluginDirectory } from "@/components/plugin-directory"
import { pluginDirectoryEntries } from "@/lib/plugins"
import type { Locale } from "@/lib/locales"

export const metadata: Metadata = localizedMetadata({
  locale: "en",
  pathname: "/plugins",
  title: "Plugins",
  description: "Directory of Syrus plugins, extension points, and bundled capabilities.",
  availableLocales: ["en", "de"]
})

export function PluginsPage({ locale }: { locale: Locale }) {
  return (
    <>
      <Nav locale={locale} />
      <main id="main">
        <PluginDirectory plugins={pluginDirectoryEntries()} locale={locale} />
      </main>
      <Footer locale={locale} />
    </>
  )
}

export default function EnglishPluginsPage() {
  return <PluginsPage locale="en" />
}
