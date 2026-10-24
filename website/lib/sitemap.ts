export type SitemapSource = { href: string }

const SITE_ORIGIN = "https://syrus-ai.dev"

const STATIC_PATHS = ["/", "/control-plane", "/download", "/plugins", "/blog"]

export function sitemapUrls(plugins: SitemapSource[], docs: SitemapSource[], posts: SitemapSource[] = []): string[] {
  const paths = [...STATIC_PATHS, ...plugins.map(({ href }) => href), ...docs.map(({ href }) => href), ...posts.map(({ href }) => href)]
  const urls = paths.map((href) => `${SITE_ORIGIN}${href === "/" ? href : `${href.replace(/\/$/, "")}/`}`)

  return [...new Set(urls)].sort()
}
