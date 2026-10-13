import { SectionHeader } from "./section";
import { RevealGroup, RevealItem } from "./reveal";
import { EntryIcon } from "./icons";
import { entryPoints } from "../lib/site";

export function EntryPoints() {
  return (
    <section id="entry-points" className="relative py-24 sm:py-32">
      <div className="wrap">
        <SectionHeader
          eyebrow="Seven ways in, one execution model"
          title="However work starts, it's tracked the same way."
          subtitle="A ticket, a narrated screen recording, a review comment, a failing check, a scheduled chore — each becomes, or updates, the same tracked job, with every attempt on one timeline. Nothing happens off the books."
        />

        <RevealGroup
          className="mt-14 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
          stagger={0.07}
        >
          {entryPoints.map((e) => (
            <RevealItem key={e.id}>
              <article className="group card flex h-full items-start gap-4 p-6 transition-all duration-300 hover:-translate-y-1 hover:border-clay/30">
                <span className="inline-flex size-10 shrink-0 items-center justify-center rounded-lg border border-white/10 bg-white/[0.03] text-clay transition-colors group-hover:border-clay/40 group-hover:text-clay-bright">
                  <EntryIcon id={e.id} className="size-[1.15rem]" />
                </span>
                <div>
                  <h3 className="text-[0.98rem] font-semibold text-cream">
                    {e.title}
                  </h3>
                  <p className="mt-1.5 text-[0.88rem] leading-relaxed text-cream-dim">
                    {e.body}
                  </p>
                </div>
              </article>
            </RevealItem>
          ))}
        </RevealGroup>
      </div>
    </section>
  );
}
