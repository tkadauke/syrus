import type { Metadata } from "next"
import { PluginsPage } from "@/components/pages/plugins-page"
import { localizedMetadata } from "@/lib/metadata"

export const metadata: Metadata = localizedMetadata({
  locale: "de",
  pathname: "/plugins",
  title: "Plugins",
  description: "Verzeichnis der Syrus-Plugins, Erweiterungspunkte und mitgelieferten Funktionen.",
  availableLocales: ["en", "de"]
})

export default function GermanPluginsPage() {
  return <PluginsPage locale="de" />
}
