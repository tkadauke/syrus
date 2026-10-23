export const locales = ["en", "de", "la"] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = "en";

// Supporting a locale must not publish it before its content is complete.
export const publishedLocales = ["en"] as const satisfies readonly Locale[];

export function isLocale(value: string): value is Locale {
  return locales.some((locale) => locale === value);
}

export function isPublishedLocale(value: Locale): boolean {
  return publishedLocales.some((locale) => locale === value);
}

export function localizedHref(href: string, locale: Locale): string {
  if (locale === defaultLocale || href.startsWith("#") || !href.startsWith("/") || href.startsWith("//")) return href;
  return href === "/" ? `/${locale}/` : `/${locale}${href}`;
}

export function localizedStaticParams(): Array<{ locale: Locale }> {
  return publishedLocales.filter((locale) => locale !== defaultLocale).map((locale) => ({ locale }));
}
