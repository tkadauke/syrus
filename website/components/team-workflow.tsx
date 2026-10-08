import { SectionHeader } from "./section";
import { Reveal, RevealGroup, RevealItem } from "./reveal";
import { workflowSteps } from "../lib/site";

const roleMeta: Record<
  string,
  { label: string; node: string; dot: string }
> = {
  human: {
    label: "Operator",
    node: "border border-clay/45 bg-ink-soft text-clay",
    dot: "border border-clay",
  },
  ai: {
    label: "Syrus AI",
    node: "clay-gradient text-on-accent",
    dot: "clay-gradient",
  },
  both: {
    label: "In tandem",
    node: "border border-clay/45 bg-clay/15 text-clay-bright",
    dot: "bg-clay-bright",
  },
};

export function TeamWorkflow() {
  const last = workflowSteps.length - 1;

  return (
    <section id="how" className="relative py-24 sm:py-32">
      <div className="wrap">
        <SectionHeader
          eyebrow="How work flows through Syrus"
          title="You steer it. Syrus opens the PR. Review stays yours."
          subtitle="Every goal turns into tracked epics and jobs, so you can see what's in progress, what's in review, and what shipped — and the merge still waits for the review policy you set."
        />

        {/* legend */}
        <Reveal className="mt-8 flex flex-wrap items-center justify-center gap-x-6 gap-y-2 text-[0.82rem] text-cream-dim">
          <span className="inline-flex items-center gap-2">
            <span className="size-2.5 rounded-full border border-clay" />
            Operator
          </span>
          <span className="inline-flex items-center gap-2">
            <span className="size-2.5 rounded-full clay-gradient" />
            Syrus AI
          </span>
          <span className="inline-flex items-center gap-2">
            <span className="size-2.5 rounded-full bg-clay-bright" />
            In tandem
          </span>
        </Reveal>

        <div className="mx-auto mt-12 max-w-3xl">
          <RevealGroup className="relative" stagger={0.1}>
            {workflowSteps.map((s, i) => {
              const m = roleMeta[s.who];
              return (
                <RevealItem key={s.action}>
                  <div className="relative flex gap-5 pb-9 last:pb-0">
                    {i < last && (
                      <span
                        aria-hidden
                        className="absolute bottom-0 left-[1.375rem] top-12 w-px bg-gradient-to-b from-clay/40 to-clay/5"
                      />
                    )}
                    <span
                      className={`relative z-10 flex size-11 shrink-0 items-center justify-center rounded-full font-mono text-[0.85rem] font-semibold ${m.node}`}
                    >
                      {i + 1}
                    </span>
                    <div className="pt-1.5">
                      <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.03] px-2.5 py-1 text-[0.72rem] font-medium text-cream-dim">
                        <span className={`size-2 rounded-full ${m.dot}`} />
                        {m.label}
                      </span>
                      <h3 className="mt-3 text-lg font-semibold tracking-tight text-cream">
                        {s.action}
                      </h3>
                      <p className="mt-1.5 max-w-xl text-[0.95rem] leading-relaxed text-cream-dim">
                        {s.note}
                      </p>
                    </div>
                  </div>
                </RevealItem>
              );
            })}
          </RevealGroup>
        </div>
      </div>
    </section>
  );
}
