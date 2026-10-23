import type { Metadata } from "next";
import { defaultLocale, localizedPath, type Locale } from "./locales.ts";

export const siteOrigin = "https://syrus-ai.dev";
export const siteTitle = "Syrus — self-hosted AI coding agents for developers";
export const siteDescription = "Syrus is an open-source, self-hosted automation harness for developers: turn issues, chats, and video walkthroughs into tracked pull requests while keeping your repos, checks, review policy, and merge queue under your control.";

export type LocalizedText = string | Partial<Record<Locale, string>>;

function textFor(value: LocalizedText, locale: Locale): string {
  if (typeof value === "string") return value;
  const text = value[locale] ?? value[defaultLocale];
  if (!text) throw new Error(`Missing ${locale} and ${defaultLocale} metadata text`);
  return text;
}

export function languageAlternates(pathname: string, availableLocales: readonly Locale[]): Record<string, string> {
  const languages = Object.fromEntries(
    availableLocales.map((locale) => [locale, localizedPath(pathname, locale)]),
  );
  if (availableLocales.includes(defaultLocale)) languages["x-default"] = localizedPath(pathname, defaultLocale);
  return languages;
}

type LocalizedMetadataOptions = {
  locale: Locale;
  pathname: string;
  title: LocalizedText;
  description: LocalizedText;
  availableLocales?: readonly Locale[];
  absoluteTitle?: boolean;
};

export function localizedMetadata({
  locale,
  pathname,
  title,
  description,
  availableLocales = [locale],
  absoluteTitle = false,
}: LocalizedMetadataOptions): Metadata {
  const localizedTitle = textFor(title, locale);
  const localizedDescription = textFor(description, locale);
  const canonical = localizedPath(pathname, locale);

  return {
    title: absoluteTitle ? { absolute: localizedTitle } : localizedTitle,
    description: localizedDescription,
    alternates: { canonical, languages: languageAlternates(pathname, availableLocales) },
    openGraph: {
      type: "website",
      url: canonical,
      siteName: "Syrus",
      title: localizedTitle,
      description: localizedDescription,
      images: [{ url: "/og.png", width: 1200, height: 630, alt: localizedTitle }],
    },
    twitter: {
      card: "summary_large_image",
      title: localizedTitle,
      description: localizedDescription,
      images: ["/og.png"],
    },
  };
}

export function siteJsonLd(locale: Locale, description: LocalizedText = siteDescription) {
  return {
    "@context": "https://schema.org",
    "@graph": [
      { "@type": "SoftwareSourceCode", "@id": `${siteOrigin}/#source`, name: "Syrus", url: siteOrigin, codeRepository: "https://github.com/tkadauke/syrus", license: "https://github.com/tkadauke/syrus/blob/main/LICENSE", programmingLanguage: ["Ruby", "TypeScript", "Go"] },
      { "@type": "SoftwareApplication", name: "Syrus", url: siteOrigin, applicationCategory: "DeveloperApplication", operatingSystem: "macOS (universal: Apple Silicon & Intel), self-hosted server (Docker/Kubernetes)", description: textFor(description, locale), inLanguage: locale, isAccessibleForFree: true, license: "https://github.com/tkadauke/syrus/blob/main/LICENSE", softwareSourceCode: { "@id": `${siteOrigin}/#source` } },
    ],
  };
}
