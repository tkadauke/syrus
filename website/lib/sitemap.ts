import { defaultLocale, localizedPath, publishedLocales, type Locale } from "./locales.ts";
import { languageAlternates, siteOrigin } from "./metadata.ts";

export type SitemapSource = { href: string; locales?: readonly Locale[] }
export type SitemapEntry = { url: string; alternates: { languages: Record<string, string> } }

const STATIC_PATHS = ["/", "/control-plane", "/download", "/plugins", "/blog"]

export function sitemapEntries(
  plugins: SitemapSource[],
  docs: SitemapSource[],
  posts: SitemapSource[] = [],
): SitemapEntry[] {
  const sources = [
    ...STATIC_PATHS.map((href) => ({ href, locales: publishedLocales })),
    ...plugins,
    ...docs,
    ...posts,
  ];
  const variants = new Map<string, Set<Locale>>();
  for (const { href, locales = [defaultLocale] } of sources) {
    const existing = variants.get(href) ?? new Set<Locale>();
    locales.forEach((locale) => existing.add(locale));
    variants.set(href, existing);
  }

  return [...variants]
    .flatMap(([href, localeSet]) => {
      const locales = [...localeSet];
      const languages = Object.fromEntries(
        Object.entries(languageAlternates(href, locales)).map(([locale, path]) => [locale, `${siteOrigin}${path}`]),
      );
      return locales.map((locale) => ({ url: `${siteOrigin}${localizedPath(href, locale)}`, alternates: { languages } }));
    })
    .sort((left, right) => left.url.localeCompare(right.url));
}
