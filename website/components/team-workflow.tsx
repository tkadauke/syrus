import { SectionHeader } from "./section"
import { Reveal, RevealGroup, RevealItem } from "./reveal"
import { marketingFor } from "../lib/marketing"
import type { Locale } from "../lib/locales"

const roleStyles: Record<string, { node: string; dot: string }> = {
  human: {
    node: "border border-clay/45 bg-ink-soft text-clay",
    dot: "border border-clay"
  },
  ai: {
    node: "clay-gradient text-on-accent",
    dot: "clay-gradient"
  },
  both: {
    node: "border border-clay/45 bg-clay/15 text-clay-bright",
    dot: "bg-clay-bright"
  }
}

export function TeamWorkflow({ locale }: { locale: Locale }) {
  const copy = marketingFor(locale).workflow
  const last = copy.steps.length - 1

  return (
    <section id="how" className="relative py-24 sm:py-32">
      <div className="wrap">
        <SectionHeader eyebrow={copy.eyebrow} title={copy.title} subtitle={copy.subtitle} />

        {/* legend */}
        <Reveal className="mt-8 flex flex-wrap items-center justify-center gap-x-6 gap-y-2 text-[0.82rem] text-cream-dim">
          <span className="inline-flex items-center gap-2">
            <span className="size-2.5 rounded-full border border-clay" />
            {copy.roles.human}
          </span>
          <span className="inline-flex items-center gap-2">
            <span className="size-2.5 rounded-full clay-gradient" />
            {copy.roles.ai}
          </span>
          <span className="inline-flex items-center gap-2">
            <span className="size-2.5 rounded-full bg-clay-bright" />
            {copy.roles.both}
          </span>
        </Reveal>

        <div className="mx-auto mt-12 max-w-3xl">
          <RevealGroup className="relative" stagger={0.1}>
            {copy.steps.map((s, i) => {
              const m = roleStyles[s.who]
              return (
                <RevealItem key={s.action}>
                  <div className="relative flex gap-5 pb-9 last:pb-0">
                    {i < last && <span aria-hidden className="absolute bottom-0 left-[1.375rem] top-12 w-px bg-gradient-to-b from-clay/40 to-clay/5" />}
                    <span
                      className={`relative z-10 flex size-11 shrink-0 items-center justify-center rounded-full font-mono text-[0.85rem] font-semibold ${m.node}`}
                    >
                      {i + 1}
                    </span>
                    <div className="pt-1.5">
                      <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.03] px-2.5 py-1 text-[0.72rem] font-medium text-cream-dim">
                        <span className={`size-2 rounded-full ${m.dot}`} />
                        {copy.roles[s.who]}
                      </span>
                      <h3 className="mt-3 text-lg font-semibold tracking-tight text-cream">{s.action}</h3>
                      <p className="mt-1.5 max-w-xl text-[0.95rem] leading-relaxed text-cream-dim">{s.note}</p>
                    </div>
                  </div>
                </RevealItem>
              )
            })}
          </RevealGroup>
        </div>
      </div>
    </section>
  )
}
