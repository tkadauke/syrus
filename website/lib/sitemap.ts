import { defaultLocale, localePublication, localizedPath, type Locale, type LocalePublication } from "./locales.ts";
import { languageAlternates, siteOrigin } from "./metadata.ts";

export type SitemapSource = { href: string; locales?: readonly Locale[] }
export type SitemapEntry = { url: string; alternates: { languages: Record<string, string> } }

const STATIC_PATHS = ["/", "/control-plane", "/download", "/plugins"]

export function sitemapEntries(
  plugins: SitemapSource[],
  docs: SitemapSource[],
  publication: LocalePublication = localePublication,
): SitemapEntry[] {
  const sources = [
    ...STATIC_PATHS.map((href) => ({ href, locales: publication.locales })),
    ...plugins,
    ...docs,
  ];
  const variants = new Map<string, Set<Locale>>();
  for (const { href, locales = [defaultLocale] } of sources) {
    const normalizedHref = localizedPath(href, defaultLocale);
    const existing = variants.get(normalizedHref) ?? new Set<Locale>();
    publication.publishedVariants(locales).forEach((locale) => existing.add(locale));
    variants.set(normalizedHref, existing);
  }

  return [...variants]
    .flatMap(([href, localeSet]) => {
      const locales = [...localeSet];
      const languages = Object.fromEntries(
        Object.entries(languageAlternates(href, locales, publication)).map(([locale, path]) => [locale, `${siteOrigin}${path}`]),
      );
      return locales.map((locale) => ({ url: `${siteOrigin}${localizedPath(href, locale)}`, alternates: { languages } }));
    })
    .sort((left, right) => left.url.localeCompare(right.url));
}
