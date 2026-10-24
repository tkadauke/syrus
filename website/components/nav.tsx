"use client"

import { useEffect, useState } from "react"
import { Logo } from "./logo"
import { ButtonLink } from "./button"
import { DownloadButton } from "./download-cta"
import { site } from "../lib/site"
import { localizedHref, type Locale } from "../lib/locales"
import { chromeFor, chromeHref } from "../lib/chrome"

export function Nav({ locale }: { locale: Locale }) {
  const copy = chromeFor(locale).nav
  const [scrolled, setScrolled] = useState(false)

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12)
    onScroll()
    window.addEventListener("scroll", onScroll, { passive: true })
    return () => window.removeEventListener("scroll", onScroll)
  }, [])

  return (
    <header className="fixed inset-x-0 top-0 z-50">
      <div
        className={`transition-colors duration-300 ${
          scrolled
            ? "border-b border-[color-mix(in_oklab,var(--color-cream)_8%,transparent)] bg-[color-mix(in_oklab,var(--color-ink)_78%,transparent)] backdrop-blur-xl"
            : "border-b border-transparent"
        }`}
      >
        <nav className="wrap flex h-16 items-center justify-between">
          <a href={localizedHref("/", locale)} aria-label={copy.homeLabel}>
            <Logo />
          </a>

          <div className="hidden items-center gap-1 xl:flex">
            {copy.links.map((l) => (
              <a
                key={l.href}
                href={chromeHref(l.href, locale, l.canonicalEnglish)}
                className="rounded-full px-3.5 py-2 text-sm text-cream-dim transition-colors hover:text-cream"
              >
                {l.label}
              </a>
            ))}
          </div>

          <div className="flex items-center gap-2">
            <a
              href={site.repositoryUrl}
              target="_blank"
              rel="noreferrer"
              className="hidden rounded-full px-3.5 py-2 text-sm font-medium text-cream-dim transition-colors hover:bg-[color-mix(in_oklab,var(--color-cream)_6%,transparent)] hover:text-cream xl:inline-flex"
            >
              {copy.github}
            </a>
            <span className="hidden xl:inline-flex">
              <ButtonLink href={localizedHref("/#walkthrough-demo", locale)} variant="ghost" size="md">
                {copy.watchDemo}
              </ButtonLink>
            </span>
            <DownloadButton locale={locale} />
          </div>
        </nav>
      </div>
    </header>
  )
}
