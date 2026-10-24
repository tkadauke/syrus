import type { Metadata, Viewport } from "next"
import { localizedMetadata, siteDescription, siteJsonLd, siteOrigin, siteTitle } from "@/lib/metadata"
import type { Locale } from "@/lib/locales"
import { MotionProvider } from "./motion-provider"
import { chromeFor } from "@/lib/chrome"

export const siteMetadata: Metadata = {
  ...localizedMetadata({ locale: "en", pathname: "/", title: siteTitle, description: siteDescription, availableLocales: ["en", "de"], absoluteTitle: true }),
  metadataBase: new URL(siteOrigin),
  title: { default: siteTitle, template: "%s · Syrus" },
  applicationName: "Syrus",
  keywords: ["Syrus", "issue to PR automation", "coding agent harness", "self-hosted", "Claude Code", "Codex", "GitHub automation"]
}

export const siteViewport: Viewport = { themeColor: "#14110d", colorScheme: "dark" }

export function SiteLayout({ children, locale }: Readonly<{ children: React.ReactNode; locale: Locale }>) {
  return (
    <html lang={locale}>
      <body>
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(siteJsonLd(locale)) }} />
        <a
          href="#main"
          className="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70] focus:rounded-full focus:bg-clay focus:px-4 focus:py-2 focus:text-sm focus:font-semibold focus:text-on-accent"
        >
          {chromeFor(locale).skipToContent}
        </a>
        <MotionProvider>{children}</MotionProvider>
      </body>
    </html>
  )
}
