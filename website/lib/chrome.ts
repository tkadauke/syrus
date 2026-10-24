import type { Locale } from "./locales.ts"

export type ChromeDictionary = {
  skipToContent: string
  nav: {
    homeLabel: string
    links: readonly { href: string; label: string; canonicalEnglish?: boolean }[]
    github: string
    watchDemo: string
  }
  footer: {
    description: string
    product: string
    getStarted: string
    build: string
    links: readonly { href: string; label: string; external?: boolean; canonicalEnglish?: boolean }[]
  }
  download: { default: string; mac: string; otherOptions: string }
  docs: { home: string; navigationLabel: string; eyebrow: string; englishSuffix: string }
  plugins: {
    eyebrow: string
    title: string
    introduction: string
    searchLabel: string
    searchPlaceholder: string
    empty: string
    detailBack: string
    pluginLabel: string
    source: string
  }
}

export const chromeDictionaries = {
  en: {
    skipToContent: "Skip to content",
    nav: {
      homeLabel: "Syrus home",
      links: [
        { href: "/#how", label: "How it works" },
        { href: "/#features", label: "Why Syrus" },
        { href: "/control-plane", label: "Control plane" },
        { href: "/#entry-points", label: "Entry points" },
        { href: "/plugins", label: "Plugins" },
        { href: "/docs", label: "Docs", canonicalEnglish: true },
        { href: "/blog", label: "Blog", canonicalEnglish: true }
      ],
      github: "GitHub",
      watchDemo: "Watch demo"
    },
    footer: {
      description: "From written intent to reviewed pull requests — with your git workflow, your reviews, and your final say kept fully intact.",
      product: "Product",
      getStarted: "Get started",
      build: "build",
      links: [
        { href: "/#how", label: "How it works" },
        { href: "/#features", label: "Why Syrus" },
        { href: "/control-plane", label: "Control plane" },
        { href: "/#entry-points", label: "Entry points" },
        { href: "/plugins", label: "Plugins" },
        { href: "/download", label: "Download" },
        { href: "/#walkthrough-demo", label: "Watch demo" },
        { href: "/docs", label: "Docs", canonicalEnglish: true },
        { href: "/blog", label: "Blog", canonicalEnglish: true },
        { href: "repository", label: "GitHub repository", external: true },
        { href: "issues", label: "File an issue", external: true }
      ]
    },
    download: { default: "Download", mac: "Download for Mac", otherOptions: "Other download options" },
    docs: { home: "Syrus Docs", navigationLabel: "Documentation", eyebrow: "Documentation", englishSuffix: "" },
    plugins: {
      eyebrow: "Extensions",
      title: "Syrus plugins",
      introduction:
        "Browse the plugin gems bundled with Syrus. Each plugin documents the extension points it owns, when to enable it, and how it fits into a Syrus installation.",
      searchLabel: "Search plugins",
      searchPlaceholder: "Search plugins by name, category, or capability",
      empty: "No plugins match that search.",
      detailBack: "Plugins",
      pluginLabel: "plugin",
      source: "Source"
    }
  },
  de: {
    skipToContent: "Zum Inhalt springen",
    nav: {
      homeLabel: "Syrus-Startseite",
      links: [
        { href: "/#how", label: "So funktioniert es" },
        { href: "/#features", label: "Warum Syrus" },
        { href: "/control-plane", label: "Steuerzentrale" },
        { href: "/#entry-points", label: "Einstiegspunkte" },
        { href: "/plugins", label: "Plugins" },
        { href: "/docs", label: "Dokumentation (Englisch)", canonicalEnglish: true },
        { href: "/blog", label: "Blog", canonicalEnglish: true }
      ],
      github: "GitHub",
      watchDemo: "Demo ansehen"
    },
    footer: {
      description:
        "Von der beschriebenen Aufgabe zum geprüften Pull Request — mit Ihrem Git-Workflow, Ihren Reviews und Ihrer endgültigen Entscheidungshoheit.",
      product: "Produkt",
      getStarted: "Erste Schritte",
      build: "Build",
      links: [
        { href: "/#how", label: "So funktioniert es" },
        { href: "/#features", label: "Warum Syrus" },
        { href: "/control-plane", label: "Steuerzentrale" },
        { href: "/#entry-points", label: "Einstiegspunkte" },
        { href: "/plugins", label: "Plugins" },
        { href: "/download", label: "Herunterladen" },
        { href: "/#walkthrough-demo", label: "Demo ansehen" },
        { href: "/docs", label: "Dokumentation (Englisch)", canonicalEnglish: true },
        { href: "/blog", label: "Blog", canonicalEnglish: true },
        { href: "repository", label: "GitHub-Repository", external: true },
        { href: "issues", label: "Issue erstellen", external: true }
      ]
    },
    download: { default: "Herunterladen", mac: "Für Mac herunterladen", otherOptions: "Weitere Download-Optionen" },
    docs: {
      home: "Syrus-Dokumentation (Englisch)",
      navigationLabel: "Dokumentation (Englisch)",
      eyebrow: "Dokumentation (Englisch)",
      englishSuffix: " (Englisch)"
    },
    plugins: {
      eyebrow: "Erweiterungen",
      title: "Syrus-Plugins",
      introduction:
        "Entdecken Sie die mit Syrus ausgelieferten Plugin-Gems. Jedes Plugin beschreibt seine Erweiterungspunkte, wann es aktiviert werden sollte und wie es sich in eine Syrus-Installation einfügt.",
      searchLabel: "Plugins durchsuchen",
      searchPlaceholder: "Plugins nach Name, Kategorie oder Funktion durchsuchen",
      empty: "Keine Plugins entsprechen dieser Suche.",
      detailBack: "Plugins",
      pluginLabel: "Plugin",
      source: "Quellcode"
    }
  }
} as const satisfies Partial<Record<Locale, ChromeDictionary>>

export type ChromeLocale = keyof typeof chromeDictionaries
export const chromeLocales = Object.keys(chromeDictionaries) as ChromeLocale[]

export function isChromeLocale(locale: Locale): locale is ChromeLocale {
  return locale in chromeDictionaries
}

export function chromeFor(locale: Locale): ChromeDictionary {
  if (!isChromeLocale(locale)) throw new Error(`No published chrome dictionary for locale: ${locale}`)
  return chromeDictionaries[locale]
}

export function chromeHref(href: string, locale: Locale, canonicalEnglish = false): string {
  if (canonicalEnglish) return href
  if (locale === "en" || href.startsWith("#") || !href.startsWith("/") || href.startsWith("//")) return href
  return href === "/" ? `/${locale}/` : `/${locale}${href}`
}
