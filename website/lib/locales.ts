export const locales = ["en", "de", "la"] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = "en";

// Supporting a locale must not publish it before its content is complete.
export const publishedLocales = ["en", "de"] as const satisfies readonly Locale[];

export class LocalePublication {
  readonly locales: readonly Locale[];
  readonly #localeSet: ReadonlySet<Locale>;

  constructor(published: readonly Locale[]) {
    this.locales = [...published];
    this.#localeSet = new Set(published);
  }

  includes(locale: Locale): boolean {
    return this.#localeSet.has(locale);
  }

  publishedVariants(candidates: readonly Locale[]): Locale[] {
    return candidates.filter((locale) => this.includes(locale));
  }
}

export const localePublication = new LocalePublication(publishedLocales);

export class LocalePublication {
  readonly locales: readonly Locale[];
  readonly #localeSet: ReadonlySet<Locale>;

  constructor(published: readonly Locale[]) {
    this.locales = [...published];
    this.#localeSet = new Set(published);
  }

  includes(locale: Locale): boolean {
    return this.#localeSet.has(locale);
  }

  publishedVariants(candidates: readonly Locale[]): Locale[] {
    return candidates.filter((locale) => this.includes(locale));
  }
}

export const localePublication = new LocalePublication(publishedLocales);

export function isLocale(value: string): value is Locale {
  return locales.some((locale) => locale === value);
}

export function isPublishedLocale(value: Locale): boolean {
  return localePublication.includes(value);
}

export function localizedHref(href: string, locale: Locale): string {
  if (locale === defaultLocale || href.startsWith("#") || !href.startsWith("/") || href.startsWith("//")) return href;
  return href === "/" ? `/${locale}/` : `/${locale}${href}`;
}

export function localizedPath(pathname: string, locale: Locale): string {
  const path = pathname === "/" ? pathname : `/${pathname.replace(/^\/+|\/+$/g, "")}/`;
  return localizedHref(path, locale);
}

export function localizedStaticParams(): Array<{ locale: Locale }> {
  return publishedLocales.filter((locale) => locale !== defaultLocale).map((locale) => ({ locale }));
}
