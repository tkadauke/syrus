import { Logo } from "./logo"
import { site } from "../lib/site"
import type { Locale } from "../lib/locales"
import { chromeFor, chromeHref } from "../lib/chrome"

export function Footer({ locale }: { locale: Locale }) {
  const copy = chromeFor(locale).footer
  const links = copy.links.map((link) => ({
    ...link,
    href: link.href === "repository" ? site.repositoryUrl : link.href === "issues" ? `${site.repositoryUrl}/issues` : link.href
  }))
  const cols = [
    { title: copy.product, links: links.slice(0, 5) },
    { title: copy.getStarted, links: links.slice(5) }
  ]
  const shortSha = site.build.sha.slice(0, 7)
  const year = new Date().getFullYear() // evaluated at build time (static page)

  return (
    <footer className="relative border-t border-white/8 py-14">
      <div className="wrap">
        <div className="grid gap-10 sm:grid-cols-2 lg:grid-cols-4">
          <div className="lg:col-span-2">
            <Logo />
            <p className="mt-4 max-w-xs text-[0.9rem] leading-relaxed text-cream-dim">{copy.description}</p>
            <p className="mt-4 font-serif text-[0.92rem] italic text-cream-faint">{site.tagline}</p>
          </div>

          {cols.map((c) => (
            <nav key={c.title} aria-label={c.title}>
              <h3 className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-cream-faint">{c.title}</h3>
              <ul className="mt-4 grid gap-2.5">
                {c.links.map((l) => (
                  <li key={l.label}>
                    <a
                      href={l.external ? l.href : chromeHref(l.href, locale, l.canonicalEnglish)}
                      {...(l.external ? { target: "_blank", rel: "noreferrer" } : {})}
                      className="text-[0.9rem] text-cream-dim transition-colors hover:text-cream"
                    >
                      {l.label}
                    </a>
                  </li>
                ))}
              </ul>
            </nav>
          ))}
        </div>

        <div className="mt-12 flex flex-col items-center gap-4 border-t border-white/6 pt-6 sm:flex-row sm:justify-between">
          <div className="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-[0.82rem] text-cream-faint">
            <span>
              © {year} Syrus · {site.domain}
            </span>
          </div>
          <span className="font-mono text-[0.72rem] text-cream-faint">
            {copy.build} {shortSha}
          </span>
        </div>
      </div>
    </footer>
  )
}
