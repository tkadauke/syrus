import { ButtonLink } from "./button"
import { DownloadCTA } from "./download-cta"
import { ArrowRight, CheckIcon } from "./icons"
import { Reveal } from "./reveal"
import { site } from "../lib/site"
import { marketingFor } from "../lib/marketing"
import { localizedHref, type Locale } from "../lib/locales"

export function Demo({ locale }: { locale: Locale }) {
  const copy = marketingFor(locale).demo
  return (
    <section id="demo" className="relative overflow-hidden py-24 sm:py-32">
      {/* warm glow behind the band */}
      <div aria-hidden className="pointer-events-none absolute inset-0 -z-0">
        <div
          className="aurora left-1/2 top-1/2 h-[420px] w-[820px] -translate-x-1/2 -translate-y-1/2 opacity-40"
          style={{
            background: "radial-gradient(closest-side, var(--aurora-a), transparent)"
          }}
        />
      </div>

      <div className="wrap relative z-10">
        <Reveal className="mx-auto max-w-6xl">
          <div className="grid overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-b from-ink-soft to-ink lg:grid-cols-2">
            <div className="border-b border-white/8 p-8 sm:p-11 lg:border-b-0 lg:border-r">
              <h2 className="text-balance text-3xl font-semibold leading-[1.08] tracking-[-0.02em] text-cream sm:text-4xl">
                {copy.title} <span className="clay-text">{copy.accent}</span>
              </h2>
              <p className="mt-4 text-[1rem] leading-relaxed text-cream-dim">{copy.body}</p>

              <div className="mt-7 flex flex-col gap-3 sm:flex-row sm:items-start">
                <DownloadCTA locale={locale} size="lg" />
                <ButtonLink href={localizedHref("/#how", locale)} variant="secondary" size="lg">
                  {copy.how}
                  <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
                </ButtonLink>
              </div>

              <ul className="mt-9 grid gap-3">
                {copy.points.map((p) => (
                  <li key={p} className="flex items-start gap-2.5 text-[0.9rem] text-cream-dim">
                    <CheckIcon className="mt-0.5 size-4 shrink-0 text-clay" />
                    {p}
                  </li>
                ))}
              </ul>
            </div>

            <div className="p-8 sm:p-11">
              <div className="grid gap-4">
                <div>
                  <p className="font-mono text-[0.72rem] uppercase tracking-[0.18em] text-clay">{copy.eyebrow}</p>
                  <h3 className="mt-2 text-xl font-semibold text-cream">{copy.start}</h3>
                  <p className="mt-3 text-[0.92rem] leading-relaxed text-cream-dim">{copy.intro}</p>
                </div>

                <div className="grid gap-3">
                  {copy.links.map((link) => (
                    <a
                      key={link.label}
                      href={link.external ? site.repositoryUrl : link.href.startsWith("/docs") ? link.href : localizedHref(link.href, locale)}
                      {...(link.external ? { target: "_blank", rel: "noreferrer" } : {})}
                      className="group rounded-2xl border border-white/10 bg-white/[0.03] p-4 transition-colors hover:border-clay/40 hover:bg-white/[0.05]"
                    >
                      <span className="flex items-center justify-between gap-4 text-[0.95rem] font-semibold text-cream">
                        {link.label}
                        {!link.external && link.href.startsWith("/docs") && locale !== "en" ? ` (${copy.docsLanguage})` : ""}
                        <ArrowRight className="size-4 shrink-0 text-clay transition-transform duration-200 group-hover:translate-x-0.5" />
                      </span>
                      <span className="mt-1.5 block text-[0.86rem] leading-relaxed text-cream-dim">{link.body}</span>
                    </a>
                  ))}
                </div>

                <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4">
                  <p className="flex items-start gap-2.5 text-[0.9rem] leading-relaxed text-cream-dim">
                    <CheckIcon className="mt-0.5 size-4 shrink-0 text-clay" />
                    {copy.noGate}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
