import type { Metadata } from "next"
import { PluginPage } from "@/components/pages/plugin-page"
import { findPlugin, pluginStaticParams } from "@/lib/plugins"
import { localizedMetadata } from "@/lib/metadata"

export const dynamic = "force-static"
export const dynamicParams = false

type PageProps = { params: Promise<{ slug: string }> }

export function generateStaticParams() {
  return pluginStaticParams()
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { slug } = await params
  const plugin = findPlugin(slug)
  if (!plugin) return {}

  return localizedMetadata({
    locale: "de",
    pathname: plugin.href,
    title: `${plugin.displayName}-Plugin`,
    description: plugin.description || plugin.summary,
    availableLocales: ["en", "de"]
  })
}

export default function GermanPluginPage(props: PageProps) {
  return <PluginPage {...props} locale="de" />
}
