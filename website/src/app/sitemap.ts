import type { MetadataRoute } from "next"
import { allDocs } from "../../lib/docs"
import { allPlugins } from "../../lib/plugins"
import { sitemapEntries } from "../../lib/sitemap"

export const dynamic = "force-static"

export default function sitemap(): MetadataRoute.Sitemap {
  return sitemapEntries(allPlugins(), allDocs())
}
