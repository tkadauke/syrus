import { ButtonLink } from "./button"
import { DownloadCTA } from "./download-cta"
import { ArrowRight, CheckIcon } from "./icons"
import { Reveal } from "./reveal"
import { infraPoints, site } from "../lib/site"

const onboardingLinks = [
  {
    label: "Read the docs",
    body: "Understand the architecture, setup flow, and operating model before you install.",
    href: "/docs",
    external: false
  },
  {
    label: "Open GitHub",
    body: "Browse the MIT-licensed source, file issues, or follow release activity in the public repo.",
    href: site.repositoryUrl,
    external: true
  },
  {
    label: "Getting started",
    body: "Install the desktop app or server, connect GitHub, configure a provider, and land the first pull request.",
    href: "/docs/getting-started",
    external: false
  }
] as const

export function Demo() {
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
                Run Syrus yourself. <span className="clay-text">Keep the project open.</span>
              </h2>
              <p className="mt-4 text-[1rem] leading-relaxed text-cream-dim">
                Download the desktop app — it sets up a complete local Syrus (Docker included) or connects to your own instance. The public docs and GitHub repo
                are the starting point for installation, operations, bug reports, and community contributions.
              </p>
              <p className="mt-3 text-[0.9rem] text-cream-faint">
                The product video above shows the core loop first: walkthrough to Job, implementation, review, and tracked cost.
              </p>

              <div className="mt-7 flex flex-col gap-3 sm:flex-row sm:items-start">
                <DownloadCTA size="lg" />
                <ButtonLink href="/#how" variant="secondary" size="lg">
                  See how it works
                  <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
                </ButtonLink>
              </div>

              <ul className="mt-9 grid gap-3">
                {infraPoints.map((p) => (
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
                  <p className="font-mono text-[0.72rem] uppercase tracking-[0.18em] text-clay">Open-source onboarding</p>
                  <h3 className="mt-2 text-xl font-semibold text-cream">Start from the public project</h3>
                  <p className="mt-3 text-[0.92rem] leading-relaxed text-cream-dim">
                    Syrus is an open-source, self-hosted project. Everything you need to evaluate it starts with the release artifacts, documentation, and
                    public issue tracker.
                  </p>
                </div>

                <div className="grid gap-3">
                  {onboardingLinks.map((link) => (
                    <a
                      key={link.label}
                      href={link.href}
                      {...(link.external ? { target: "_blank", rel: "noreferrer" } : {})}
                      className="group rounded-2xl border border-white/10 bg-white/[0.03] p-4 transition-colors hover:border-clay/40 hover:bg-white/[0.05]"
                    >
                      <span className="flex items-center justify-between gap-4 text-[0.95rem] font-semibold text-cream">
                        {link.label}
                        <ArrowRight className="size-4 shrink-0 text-clay transition-transform duration-200 group-hover:translate-x-0.5" />
                      </span>
                      <span className="mt-1.5 block text-[0.86rem] leading-relaxed text-cream-dim">{link.body}</span>
                    </a>
                  ))}
                </div>

                <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4">
                  <p className="flex items-start gap-2.5 text-[0.9rem] leading-relaxed text-cream-dim">
                    <CheckIcon className="mt-0.5 size-4 shrink-0 text-clay" />
                    No account signup, vendor workspace, or product gate: fork it, install it, inspect it, and run it against repositories you control.
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
