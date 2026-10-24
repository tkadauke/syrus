import type { MetadataRoute } from "next"
import { allDocs } from "../../lib/docs"
import { allPlugins } from "../../lib/plugins"
import { allPosts } from "../../lib/blog"
import { sitemapEntries } from "../../lib/sitemap"

export const dynamic = "force-static"

export default function sitemap(): MetadataRoute.Sitemap {
  return sitemapEntries(
    allPlugins().map((plugin) => ({ href: plugin.href, locales: ["en", "de"] })),
    allDocs(),
    [{ href: "/blog" }, ...allPosts()]
  )
}
