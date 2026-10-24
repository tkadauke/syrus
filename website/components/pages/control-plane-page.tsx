import type { Metadata } from "next"
import { localizedMetadata } from "@/lib/metadata"
import { ArrowRight, CheckIcon } from "@/components/icons"
import { ButtonLink } from "@/components/button"
import { Footer } from "@/components/footer"
import { Nav } from "@/components/nav"
import { Reveal, RevealGroup, RevealItem } from "@/components/reveal"
import { SectionHeader } from "@/components/section"
import { ScreenshotFrame } from "@/components/screenshot-frame"
import type { Locale } from "@/lib/locales"
import { localizedHref } from "@/lib/locales"
import { controlPlaneFor } from "@/lib/control-plane-copy"

export const metadata: Metadata = localizedMetadata({
  locale: "en",
  pathname: "/control-plane",
  title: "Control Plane",
  description: "Syrus is the deterministic control plane around coding agents: durable Jobs, scoped credentials, review notes, CI repair, and landing policy.",
  availableLocales: ["en", "de"]
})

function MiniPipeline({ locale }: { locale: Locale }) {
  const copy = controlPlaneFor(locale)

  return (
    <div
      role="img"
      aria-label={copy.pipelineLabel}
      className="overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-b from-ink-soft to-ink shadow-[0_40px_130px_-54px_rgba(0,0,0,0.9)]"
    >
      <div className="flex items-center justify-between border-b border-white/8 px-4 py-3">
        <div className="flex items-center gap-2">
          <span className="size-2.5 rounded-full bg-clay-bright" />
          <span className="size-2.5 rounded-full bg-cream-faint/50" />
          <span className="size-2.5 rounded-full bg-cream-faint/30" />
        </div>
        <span className="font-mono text-[0.7rem] text-cream-faint">{copy.pipelineTitle}</span>
      </div>
      <div className="grid sm:grid-cols-[11rem_minmax(0,1fr)]">
        <aside className="hidden border-r border-white/8 bg-white/[0.025] p-4 sm:block">
          {copy.sidebar.map((item, index) => (
            <div key={item} className={`mb-2 rounded-xl px-3 py-2 text-sm ${index === 1 ? "bg-clay/15 text-cream" : "text-cream-dim"}`}>
              {item}
            </div>
          ))}
        </aside>
        <div className="p-4 sm:p-6">
          <div className="flex flex-col gap-3 border-b border-white/8 pb-5 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 className="text-xl font-semibold text-cream">{copy.pipelineHeading}</h2>
              <p className="mt-1 font-mono text-[0.72rem] text-cream-faint">{copy.pipelinePath}</p>
            </div>
            <span className="w-fit rounded-full bg-[#82c78f]/90 px-3 py-1 text-xs font-semibold text-[#172115]">{copy.ready}</span>
          </div>
          <div className="mt-5 grid gap-3">
            {copy.stages.map(([stage, meta], index) => (
              <div
                key={stage}
                className="grid gap-3 rounded-2xl border border-white/8 bg-white/[0.03] p-3 sm:grid-cols-[6rem_minmax(0,1fr)_6rem] sm:items-center"
              >
                <span className="text-sm font-semibold text-cream">{stage}</span>
                <span className="h-2 overflow-hidden rounded-full bg-white/8">
                  <span className="block h-full rounded-full bg-gradient-to-r from-clay to-[#82c78f]" style={{ width: `${100 - index * 11}%` }} />
                </span>
                <span className="font-mono text-[0.7rem] text-cream-faint">{meta}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

export function ControlPlanePage({ locale }: { locale: Locale }) {
  const copy = controlPlaneFor(locale)
  return (
    <>
      <Nav locale={locale} />
      <main id="main">
        <section className="grain relative overflow-hidden pt-28 pb-16 sm:pt-36 sm:pb-24">
          <div aria-hidden className="absolute inset-0 -z-0">
            <div
              className="aurora animate-float-slow left-1/2 top-[-10%] h-[520px] w-[760px] -translate-x-1/2"
              style={{
                background: "radial-gradient(closest-side, var(--aurora-a), transparent)"
              }}
            />
            <div
              className="aurora right-[4%] top-[30%] h-[360px] w-[360px] opacity-35"
              style={{
                background: "radial-gradient(closest-side, var(--aurora-b), transparent)"
              }}
            />
          </div>

          <div className="wrap relative z-10 grid gap-12 lg:grid-cols-[minmax(0,0.92fr)_minmax(26rem,1.08fr)] lg:items-center">
            <Reveal>
              <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.03] px-3.5 py-1.5 text-[0.78rem] text-cream-dim backdrop-blur">
                <span className="size-1.5 rounded-full clay-gradient" />
                {copy.eyebrow}
              </span>
              <h1 className="mt-7 text-balance text-[2.7rem] font-semibold leading-[1.04] text-cream sm:text-6xl">
                {copy.heroLead} <span className="clay-text">{copy.heroAccent}</span>
              </h1>
              <p className="mt-6 max-w-2xl text-pretty text-[1.04rem] leading-relaxed text-cream-dim sm:text-[1.13rem]">{copy.heroBody}</p>
              <div className="mt-8 flex flex-col gap-3 sm:flex-row">
                <ButtonLink href="#comparison" size="lg">
                  {copy.compare}
                  <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
                </ButtonLink>
                <ButtonLink href={localizedHref("/plugins", locale)} variant="secondary" size="lg">
                  {copy.plugins}
                </ButtonLink>
              </div>
              <div className="mt-6 flex flex-wrap gap-x-5 gap-y-2 text-[0.82rem] text-cream-faint">
                {copy.chips.map((chip) => (
                  <span key={chip} className="inline-flex items-center gap-1.5">
                    <span className="size-1 rounded-full bg-clay" />
                    {chip}
                  </span>
                ))}
              </div>
            </Reveal>

            <Reveal delay={0.1}>
              <MiniPipeline locale={locale} />
            </Reveal>
          </div>
        </section>

        <section id="comparison" className="relative py-24 sm:py-32">
          <div className="wrap">
            <SectionHeader align="left" eyebrow={copy.comparisonEyebrow} title={copy.comparisonTitle} subtitle={copy.comparisonSubtitle} />

            <RevealGroup className="mt-12 grid gap-4 lg:grid-cols-2">
              <RevealItem>
                <article className="h-full overflow-hidden rounded-3xl border border-white/10 bg-white/[0.03]">
                  <div className="flex items-center justify-between gap-4 border-b border-white/8 p-5">
                    <h2 className="text-xl font-semibold text-cream">{copy.rawTitle}</h2>
                    <span className="rounded-full bg-white/6 px-3 py-1 font-mono text-[0.68rem] uppercase text-cream-faint">{copy.rawState}</span>
                  </div>
                  <ul className="grid gap-2 p-3">
                    {copy.rawRows.map((row) => (
                      <li key={row} className="flex gap-3 rounded-2xl bg-white/[0.025] p-4 text-[0.95rem] leading-relaxed text-cream-dim">
                        <span className="mt-1 flex size-5 shrink-0 items-center justify-center rounded-full bg-white/7 font-mono text-xs text-cream-faint">
                          -
                        </span>
                        {row}
                      </li>
                    ))}
                  </ul>
                </article>
              </RevealItem>

              <RevealItem>
                <article className="h-full overflow-hidden rounded-3xl border border-clay/35 bg-[color-mix(in_oklab,var(--color-ink-soft)_88%,transparent)] shadow-[0_30px_90px_-60px_var(--accent-shadow)]">
                  <div className="flex items-center justify-between gap-4 border-b border-clay/20 p-5">
                    <h2 className="text-xl font-semibold text-cream">{copy.syrusTitle}</h2>
                    <span className="rounded-full bg-clay/15 px-3 py-1 font-mono text-[0.68rem] uppercase text-clay-bright">{copy.syrusState}</span>
                  </div>
                  <ul className="grid gap-2 p-3">
                    {copy.syrusRows.map((row) => (
                      <li key={row} className="flex gap-3 rounded-2xl bg-white/[0.035] p-4 text-[0.95rem] leading-relaxed text-cream-dim">
                        <CheckIcon className="mt-1 size-5 shrink-0 text-clay" />
                        {row}
                      </li>
                    ))}
                  </ul>
                </article>
              </RevealItem>
            </RevealGroup>
          </div>
        </section>

        <section id="plugins" className="relative py-24 sm:py-32">
          <div className="wrap">
            <SectionHeader eyebrow={copy.capabilitiesEyebrow} title={copy.capabilitiesTitle} subtitle={copy.capabilitiesSubtitle} />

            <RevealGroup className="mt-12 grid gap-4 md:grid-cols-2 xl:grid-cols-3">
              {copy.cards.map((card) => (
                <RevealItem key={card.title}>
                  <article className="card h-full p-7">
                    <div className="flex size-11 items-center justify-center rounded-xl border border-clay/25 bg-clay/10 font-mono text-sm font-semibold text-clay-bright">
                      {card.title
                        .split(" ")
                        .map((word) => word[0])
                        .join("")
                        .slice(0, 2)}
                    </div>
                    <p className="mt-5 font-mono text-[0.68rem] uppercase text-clay">{card.eyebrow}</p>
                    <h2 className="mt-2 text-xl font-semibold text-cream">{card.title}</h2>
                    <p className="mt-3 text-[0.94rem] leading-relaxed text-cream-dim">{card.body}</p>
                  </article>
                </RevealItem>
              ))}
            </RevealGroup>
          </div>
        </section>

        <section className="border-y border-white/8 bg-white/[0.025] py-16">
          <div className="wrap">
            <Reveal className="mx-auto max-w-5xl">
              <p className="text-balance text-3xl font-semibold leading-[1.12] text-cream sm:text-5xl">
                {copy.statementLead} <span className="clay-text">{copy.statementAccent}</span> {copy.statementTail}
              </p>
              <p className="mt-5 max-w-3xl text-[1rem] leading-relaxed text-cream-dim">{copy.statementBody}</p>
            </Reveal>
          </div>
        </section>

        <section id="workflow" className="relative py-24 sm:py-32">
          <div className="wrap">
            <SectionHeader eyebrow={copy.loopEyebrow} title={copy.loopTitle} subtitle={copy.loopSubtitle} />

            <RevealGroup className="mt-12 grid gap-3 lg:grid-cols-5">
              {copy.loop.map((step, index) => (
                <RevealItem key={step.title}>
                  <article className="h-full rounded-2xl border border-white/10 bg-white/[0.035] p-5">
                    <span className="flex size-8 items-center justify-center rounded-xl clay-gradient text-sm font-bold text-on-accent">{index + 1}</span>
                    <h2 className="mt-5 text-lg font-semibold text-cream">{step.title}</h2>
                    <p className="mt-2 text-[0.9rem] leading-relaxed text-cream-dim">{step.body}</p>
                  </article>
                </RevealItem>
              ))}
            </RevealGroup>

            <Reveal className="mt-16">
              <div className="grid gap-10 lg:grid-cols-[minmax(0,1fr)_24rem] lg:items-center">
                <ScreenshotFrame desktopSrc="/product-screenshot.png" locale={locale} />
                <div>
                  <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-clay">{copy.surfaceEyebrow}</p>
                  <h2 className="mt-3 text-3xl font-semibold leading-tight text-cream">{copy.surfaceTitle}</h2>
                  <p className="mt-4 text-[1rem] leading-relaxed text-cream-dim">{copy.surfaceBody}</p>
                  <ButtonLink href="/docs/what-is-syrus" variant="secondary" className="mt-7">
                    {copy.docs}
                    <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
                  </ButtonLink>
                </div>
              </div>
            </Reveal>
          </div>
        </section>
      </main>
      <Footer locale={locale} />
    </>
  )
}

export default function EnglishControlPlanePage() {
  return <ControlPlanePage locale="en" />
}
