import { SectionHeader } from "./section";
import { RevealGroup, RevealItem } from "./reveal";
import { FeatureIcon } from "./icons";
import { features } from "../lib/site";

export function Features() {
  return (
    <section id="features" className="relative py-24 sm:py-32">
      <div className="wrap">
        <SectionHeader
          eyebrow="Why Syrus"
          title="Leverage AI — with the control an owner needs."
          subtitle="More output, real guardrails, and full visibility into what's being built — so you can move faster without gambling on quality."
        />

        <RevealGroup className="mt-14 grid gap-4 sm:grid-cols-2" stagger={0.1}>
          {features.map((f) => {
            const content = (
              <>
                <div
                  aria-hidden
                  className="pointer-events-none absolute -right-16 -top-16 size-40 rounded-full bg-clay/10 opacity-0 blur-2xl transition-opacity duration-500 group-hover:opacity-100"
                />
                <span className="relative inline-flex size-11 items-center justify-center rounded-xl border border-white/10 bg-white/[0.03] text-clay">
                  <FeatureIcon id={f.id} className="size-5" />
                </span>
                <h3 className="relative mt-5 text-lg font-semibold tracking-tight text-cream">
                  {f.title}
                </h3>
                <p className="relative mt-2.5 text-[0.95rem] leading-relaxed text-cream-dim">
                  {f.body}
                </p>
              </>
            );

            return (
              <RevealItem key={f.id}>
                {"href" in f ? (
                  <a
                    className="group card relative block h-full overflow-hidden p-7 transition-all duration-300 hover:-translate-y-1 hover:border-clay/30 focus:outline-none focus:ring-2 focus:ring-clay/70 focus:ring-offset-2 focus:ring-offset-ink"
                    href={f.href}
                  >
                    {content}
                  </a>
                ) : (
                  <article className="group card relative h-full overflow-hidden p-7 transition-all duration-300 hover:-translate-y-1 hover:border-clay/30">
                    {content}
                  </article>
                )}
              </RevealItem>
            );
          })}
        </RevealGroup>
      </div>
    </section>
  );
}
