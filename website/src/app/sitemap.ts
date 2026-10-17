import type { MetadataRoute } from "next"
import { allDocs } from "../../lib/docs"
import { allPlugins } from "../../lib/plugins"
import { sitemapUrls } from "../../lib/sitemap"

export const dynamic = "force-static"

export default function sitemap(): MetadataRoute.Sitemap {
  return sitemapUrls(allPlugins(), allDocs()).map((url) => ({ url }))
}
