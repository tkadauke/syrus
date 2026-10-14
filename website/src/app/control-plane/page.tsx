import type { Metadata } from "next";
import { ArrowRight, CheckIcon } from "../../../components/icons";
import { ButtonLink } from "../../../components/button";
import { Footer } from "../../../components/footer";
import { Nav } from "../../../components/nav";
import { Reveal, RevealGroup, RevealItem } from "../../../components/reveal";
import { SectionHeader } from "../../../components/section";
import { ScreenshotFrame } from "../../../components/screenshot-frame";

export const metadata: Metadata = {
  title: "Control Plane",
  description:
    "Syrus is the deterministic control plane around coding agents: durable Jobs, scoped credentials, review notes, CI repair, and landing policy.",
  alternates: { canonical: "/control-plane" },
};

const rawAgentRows = [
  "Session context lives in chat, shell history, or a local transcript.",
  "Tool calls and credentials depend on whatever the session was handed.",
  "Review feedback is prose the agent must reinterpret later.",
  "Retry, rebase, repair, and merge policy remain manual coordination.",
];

const syrusRows = [
  "Durable Jobs, Workflows, Steps, and Runs preserve every attempt.",
  "Credential gates scope GitHub, model provider, browser, and plugin access.",
  "Review Notes stay attached to diffs, files, and follow-up work.",
  "The operator UI, CI repair loop, and landing queue move work to merge.",
];

const controlPlaneCards = [
  {
    title: "Provider adapters",
    eyebrow: "Claude · Codex · Muse · Antigravity",
    body: "Syrus can route work to multiple coding-agent backends while keeping the surrounding workflow, transcript, and policy model consistent.",
  },
  {
    title: "Credential Store",
    eyebrow: "Scoped access",
    body: "Agents receive bounded credentials for the task at hand, with operator-visible state instead of ad hoc secrets in a prompt window.",
  },
  {
    title: "Source plugins",
    eyebrow: "Issue intake",
    body: "GitHub issues, PR feedback, chats, schedules, and plugin-owned sources all enter the same durable Job pipeline.",
  },
  {
    title: "Review Notes",
    eyebrow: "Diff-anchored debt",
    body: "Feedback becomes structured, file-aware work the system can track, apply, and repair without losing reviewer intent.",
  },
  {
    title: "Browser and previews",
    eyebrow: "Visual context",
    body: "Preview and browser plugins give agents inspectable product state while keeping the evidence attached to the work record.",
  },
  {
    title: "Insights and briefings",
    eyebrow: "Operational memory",
    body: "Syrus turns runs, costs, failures, and recurring patterns into dashboards and briefings the team can act on.",
  },
];

const loopSteps = [
  {
    title: "Intake",
    body: "A labeled issue, chat proposal, schedule, or PR review becomes a tracked Job.",
  },
  {
    title: "Plan",
    body: "Syrus scopes work into bounded attempts with provider, repository, and execution requirements.",
  },
  {
    title: "Execute",
    body: "The chosen agent works inside an isolated workspace with captured prompts, tools, and diffs.",
  },
  {
    title: "Review",
    body: "Checks, reviewer notes, and repair attempts stay attached to the exact work they concern.",
  },
  {
    title: "Land",
    body: "Approval triggers rebase, final checks, dependency ordering, and merge policy.",
  },
];

function MiniPipeline() {
  const stages = [
    ["Intake", "GitHub issue"],
    ["Workflow", "Codex run"],
    ["Review", "2 notes"],
    ["Landing", "approved"],
  ] as const;

  return (
    <div
      role="img"
      aria-label="Syrus control plane showing intake, workflow, review, and landing state"
      className="overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-b from-ink-soft to-ink shadow-[0_40px_130px_-54px_rgba(0,0,0,0.9)]"
    >
      <div className="flex items-center justify-between border-b border-white/8 px-4 py-3">
        <div className="flex items-center gap-2">
          <span className="size-2.5 rounded-full bg-clay-bright" />
          <span className="size-2.5 rounded-full bg-cream-faint/50" />
          <span className="size-2.5 rounded-full bg-cream-faint/30" />
        </div>
        <span className="font-mono text-[0.7rem] text-cream-faint">
          workflow control plane
        </span>
      </div>
      <div className="grid sm:grid-cols-[11rem_minmax(0,1fr)]">
        <aside className="hidden border-r border-white/8 bg-white/[0.025] p-4 sm:block">
          {["Jobs", "Workflows", "Credentials", "Review", "Landing"].map(
            (item, index) => (
              <div
                key={item}
                className={`mb-2 rounded-xl px-3 py-2 text-sm ${
                  index === 1
                    ? "bg-clay/15 text-cream"
                    : "text-cream-dim"
                }`}
              >
                {item}
              </div>
            ),
          )}
        </aside>
        <div className="p-4 sm:p-6">
          <div className="flex flex-col gap-3 border-b border-white/8 pb-5 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 className="text-xl font-semibold text-cream">
                Browser review and CI repair
              </h2>
              <p className="mt-1 font-mono text-[0.72rem] text-cream-faint">
                issue to workflow to pull request
              </p>
            </div>
            <span className="w-fit rounded-full bg-[#82c78f]/90 px-3 py-1 text-xs font-semibold text-[#172115]">
              ready to land
            </span>
          </div>
          <div className="mt-5 grid gap-3">
            {stages.map(([stage, meta], index) => (
              <div
                key={stage}
                className="grid gap-3 rounded-2xl border border-white/8 bg-white/[0.03] p-3 sm:grid-cols-[6rem_minmax(0,1fr)_6rem] sm:items-center"
              >
                <span className="text-sm font-semibold text-cream">{stage}</span>
                <span className="h-2 overflow-hidden rounded-full bg-white/8">
                  <span
                    className="block h-full rounded-full bg-gradient-to-r from-clay to-[#82c78f]"
                    style={{ width: `${100 - index * 11}%` }}
                  />
                </span>
                <span className="font-mono text-[0.7rem] text-cream-faint">
                  {meta}
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

export default function ControlPlanePage() {
  return (
    <>
      <Nav />
      <main id="main">
        <section className="grain relative overflow-hidden pt-28 pb-16 sm:pt-36 sm:pb-24">
          <div aria-hidden className="absolute inset-0 -z-0">
            <div
              className="aurora animate-float-slow left-1/2 top-[-10%] h-[520px] w-[760px] -translate-x-1/2"
              style={{
                background:
                  "radial-gradient(closest-side, var(--aurora-a), transparent)",
              }}
            />
            <div
              className="aurora right-[4%] top-[30%] h-[360px] w-[360px] opacity-35"
              style={{
                background:
                  "radial-gradient(closest-side, var(--aurora-b), transparent)",
              }}
            />
          </div>

          <div className="wrap relative z-10 grid gap-12 lg:grid-cols-[minmax(0,0.92fr)_minmax(26rem,1.08fr)] lg:items-center">
            <Reveal>
              <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.03] px-3.5 py-1.5 text-[0.78rem] text-cream-dim backdrop-blur">
                <span className="size-1.5 rounded-full clay-gradient" />
                The deterministic harness around agent work
              </span>
              <h1 className="mt-7 text-balance text-[2.7rem] font-semibold leading-[1.04] text-cream sm:text-6xl">
                Agents write code.{" "}
                <span className="clay-text">Syrus lands work.</span>
              </h1>
              <p className="mt-6 max-w-2xl text-pretty text-[1.04rem] leading-relaxed text-cream-dim sm:text-[1.13rem]">
                Claude Code, Codex, Muse Code, Antigravity, and skills can all
                produce meaningful changes. Syrus adds the control plane around
                them: durable Jobs, typed workflows, credential gates, review
                debt, operator UI, CI repair, and landing policy.
              </p>
              <div className="mt-8 flex flex-col gap-3 sm:flex-row">
                <ButtonLink href="#comparison" size="lg">
                  Compare the harness
                  <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
                </ButtonLink>
                <ButtonLink href="/plugins" variant="secondary" size="lg">
                  Explore plugins
                </ButtonLink>
              </div>
              <div className="mt-6 flex flex-wrap gap-x-5 gap-y-2 text-[0.82rem] text-cream-faint">
                {[
                  "Self-hosted",
                  "Provider-neutral",
                  "GitHub-native",
                  "Human-gated landing",
                ].map((chip) => (
                  <span key={chip} className="inline-flex items-center gap-1.5">
                    <span className="size-1 rounded-full bg-clay" />
                    {chip}
                  </span>
                ))}
              </div>
            </Reveal>

            <Reveal delay={0.1}>
              <MiniPipeline />
            </Reveal>
          </div>
        </section>

        <section id="comparison" className="relative py-24 sm:py-32">
          <div className="wrap">
            <SectionHeader
              align="left"
              eyebrow="Control plane comparison"
              title="The agent session is powerful. The system around it makes the work durable."
              subtitle="Syrus does not assume agents are helpless without tools. It gives teams a repeatable place for state, permissions, review, repair, and landing to live after the model turn ends."
            />

            <RevealGroup className="mt-12 grid gap-4 lg:grid-cols-2">
              <RevealItem>
                <article className="h-full overflow-hidden rounded-3xl border border-white/10 bg-white/[0.03]">
                  <div className="flex items-center justify-between gap-4 border-b border-white/8 p-5">
                    <h2 className="text-xl font-semibold text-cream">
                      Raw agent session
                    </h2>
                    <span className="rounded-full bg-white/6 px-3 py-1 font-mono text-[0.68rem] uppercase text-cream-faint">
                      ephemeral
                    </span>
                  </div>
                  <ul className="grid gap-2 p-3">
                    {rawAgentRows.map((row) => (
                      <li
                        key={row}
                        className="flex gap-3 rounded-2xl bg-white/[0.025] p-4 text-[0.95rem] leading-relaxed text-cream-dim"
                      >
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
                    <h2 className="text-xl font-semibold text-cream">
                      Syrus harness
                    </h2>
                    <span className="rounded-full bg-clay/15 px-3 py-1 font-mono text-[0.68rem] uppercase text-clay-bright">
                      durable
                    </span>
                  </div>
                  <ul className="grid gap-2 p-3">
                    {syrusRows.map((row) => (
                      <li
                        key={row}
                        className="flex gap-3 rounded-2xl bg-white/[0.035] p-4 text-[0.95rem] leading-relaxed text-cream-dim"
                      >
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
            <SectionHeader
              eyebrow="Bundled control-plane capabilities"
              title="Plugins add hands; Syrus keeps the lifecycle coherent."
              subtitle="Adapters, browser context, source providers, review surfaces, and operational briefings plug into the same Job model instead of becoming separate side channels."
            />

            <RevealGroup className="mt-12 grid gap-4 md:grid-cols-2 xl:grid-cols-3">
              {controlPlaneCards.map((card) => (
                <RevealItem key={card.title}>
                  <article className="card h-full p-7">
                    <div className="flex size-11 items-center justify-center rounded-xl border border-clay/25 bg-clay/10 font-mono text-sm font-semibold text-clay-bright">
                      {card.title
                        .split(" ")
                        .map((word) => word[0])
                        .join("")
                        .slice(0, 2)}
                    </div>
                    <p className="mt-5 font-mono text-[0.68rem] uppercase text-clay">
                      {card.eyebrow}
                    </p>
                    <h2 className="mt-2 text-xl font-semibold text-cream">
                      {card.title}
                    </h2>
                    <p className="mt-3 text-[0.94rem] leading-relaxed text-cream-dim">
                      {card.body}
                    </p>
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
                Other systems give agents more hands.{" "}
                <span className="clay-text">
                  Syrus gives the team a control plane
                </span>{" "}
                for the work those hands produce.
              </p>
              <p className="mt-5 max-w-3xl text-[1rem] leading-relaxed text-cream-dim">
                The result is not just more generated code. It is a tracked path
                from intent to pull request to approved merge, with the same
                audit trail and review discipline teams expect from human work.
              </p>
            </Reveal>
          </div>
        </section>

        <section id="workflow" className="relative py-24 sm:py-32">
          <div className="wrap">
            <SectionHeader
              eyebrow="Product loop"
              title="One loop from intake to landing."
              subtitle="Every entry point runs through the same lifecycle, so operators can see where work is, why it is blocked, and what happens next."
            />

            <RevealGroup className="mt-12 grid gap-3 lg:grid-cols-5">
              {loopSteps.map((step, index) => (
                <RevealItem key={step.title}>
                  <article className="h-full rounded-2xl border border-white/10 bg-white/[0.035] p-5">
                    <span className="flex size-8 items-center justify-center rounded-xl clay-gradient text-sm font-bold text-on-accent">
                      {index + 1}
                    </span>
                    <h2 className="mt-5 text-lg font-semibold text-cream">
                      {step.title}
                    </h2>
                    <p className="mt-2 text-[0.9rem] leading-relaxed text-cream-dim">
                      {step.body}
                    </p>
                  </article>
                </RevealItem>
              ))}
            </RevealGroup>

            <Reveal className="mt-16">
              <div className="grid gap-10 lg:grid-cols-[minmax(0,1fr)_24rem] lg:items-center">
                <ScreenshotFrame desktopSrc="/product-screenshot.png" />
                <div>
                  <p className="font-mono text-[0.72rem] uppercase tracking-[0.16em] text-clay">
                    Operator surface
                  </p>
                  <h2 className="mt-3 text-3xl font-semibold leading-tight text-cream">
                    The UI is not decoration. It is the work ledger.
                  </h2>
                  <p className="mt-4 text-[1rem] leading-relaxed text-cream-dim">
                    Jobs, attempts, transcripts, diffs, costs, credentials,
                    checks, and landing state are visible to the team. Agents
                    can keep moving, but the operator never loses the thread.
                  </p>
                  <ButtonLink
                    href="/docs/what-is-syrus"
                    variant="secondary"
                    className="mt-7"
                  >
                    Read what Syrus is
                    <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
                  </ButtonLink>
                </div>
              </div>
            </Reveal>
          </div>
        </section>
      </main>
      <Footer />
    </>
  );
}
