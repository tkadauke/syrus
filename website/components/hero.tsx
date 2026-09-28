"use client";

import { motion } from "motion/react";
import { ButtonLink } from "./button";
import { DownloadCTA } from "./download-cta";
import { ScreenshotFrame } from "./screenshot-frame";
import { ArrowRight } from "./icons";
import { hero, site } from "../lib/site";

const ease = [0.22, 1, 0.36, 1] as const;

const chips = [
  "MIT open source",
  "Self-hosted on your infra",
  "Human review on every merge",
];

export function Hero({
  desktopSrc = null,
  mobileSrc = null,
}: {
  desktopSrc?: string | null;
  mobileSrc?: string | null;
}) {
  // Reduced-motion is handled globally by <MotionProvider> — no branching here
  // (a divergent hydration tree left SSR opacity:0 stuck for those users).
  const container = {
    hidden: {},
    show: { transition: { staggerChildren: 0.12, delayChildren: 0.05 } },
  };
  const item = {
    hidden: { opacity: 0, y: 24 },
    show: { opacity: 1, y: 0, transition: { duration: 0.75, ease } },
  };

  return (
    <section
      id="top"
      className="grain relative overflow-hidden pt-28 pb-16 sm:pt-36 sm:pb-24"
    >
      {/* ambient glow */}
      <div aria-hidden className="absolute inset-0 -z-0">
        <div
          className="aurora animate-float-slow left-1/2 top-[-10%] h-[520px] w-[720px] -translate-x-1/2"
          style={{
            background:
              "radial-gradient(closest-side, var(--aurora-a), transparent)",
          }}
        />
        <div
          className="aurora left-[8%] top-[30%] h-[360px] w-[360px]"
          style={{
            background:
              "radial-gradient(closest-side, var(--aurora-b), transparent)",
          }}
        />
        <div
          className="aurora right-[6%] top-[8%] h-[320px] w-[320px]"
          style={{
            background:
              "radial-gradient(closest-side, var(--aurora-c), transparent)",
          }}
        />
      </div>

      <div className="wrap relative z-10">
        <motion.div
          data-reveal
          variants={container}
          initial="hidden"
          animate="show"
          className="mx-auto max-w-3xl text-center"
        >
          <motion.div variants={item}>
            <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.03] px-3.5 py-1.5 text-[0.78rem] text-cream-dim backdrop-blur">
              <span className="size-1.5 rounded-full clay-gradient" />
              {hero.eyebrow}
            </span>
          </motion.div>

          <motion.h1
            variants={item}
            className="mt-7 text-balance text-[2.6rem] font-semibold leading-[1.04] tracking-[-0.02em] sm:text-6xl"
          >
            <span className="text-cream">{hero.titleLead}</span>
            <br />
            <span className="clay-text">{hero.titleAccent}</span>
          </motion.h1>

          <motion.p
            variants={item}
            className="mx-auto mt-6 max-w-2xl text-pretty text-[1.02rem] leading-relaxed text-cream-dim sm:text-[1.12rem]"
          >
            {hero.subtitle}
          </motion.p>

          <motion.div
            variants={item}
            className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row sm:items-start"
          >
            <DownloadCTA size="lg" />
            <ButtonLink
              href="/#walkthrough-demo"
              variant="secondary"
              size="lg"
              className="w-full sm:w-auto"
            >
              Watch the product demo
              <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
            </ButtonLink>
          </motion.div>

          <motion.div
            variants={item}
            className="mt-6 flex flex-wrap items-center justify-center gap-x-5 gap-y-2 text-[0.8rem] text-cream-faint"
          >
            {chips.map((c) => (
              <span key={c} className="inline-flex items-center gap-1.5">
                <span className="size-1 rounded-full bg-clay" />
                {c}
              </span>
            ))}
          </motion.div>

          <motion.a
            variants={item}
            href="/docs/dogfooding"
            className="group mx-auto mt-8 grid max-w-2xl gap-4 rounded-2xl border border-clay/35 bg-[color-mix(in_oklab,var(--color-ink-soft)_78%,transparent)] p-4 text-left shadow-[0_24px_70px_-48px_var(--accent-shadow)] transition-all duration-200 hover:-translate-y-0.5 hover:border-clay/60 sm:grid-cols-[8rem_minmax(0,1fr)] sm:items-center sm:p-5"
          >
            <span className="text-center text-5xl font-semibold tracking-[-0.02em] clay-text sm:text-left">
              95.1%
            </span>
            <span>
              <span className="block font-mono text-[0.72rem] uppercase tracking-[0.16em] text-clay-bright">
                Built through its own PR loop
              </span>
              <span className="mt-2 block text-sm leading-relaxed text-cream-dim sm:text-[0.95rem]">
                of Syrus's merged pull requests were written by Syrus itself.
                <span className="ml-1 text-cream transition-colors group-hover:text-clay-bright">
                  Read the receipts
                  <ArrowRight className="ml-1 inline size-3.5 transition-transform duration-200 group-hover:translate-x-0.5" />
                </span>
              </span>
            </span>
          </motion.a>
        </motion.div>

        {/* product shot */}
        <motion.div
          data-reveal
          initial={{ opacity: 0, y: 40, scale: 0.98 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 0.9, delay: 0.4, ease }}
          className="mx-auto mt-16 max-w-5xl"
        >
          <ScreenshotFrame desktopSrc={desktopSrc} mobileSrc={mobileSrc} />
          <p className="mt-3 text-center font-serif text-[0.95rem] italic text-cream-faint">
            {site.tagline}{" "}
            <span className="not-italic">
              {site.taglineTranslation} {site.taglineAttribution}
            </span>
          </p>
        </motion.div>
      </div>
    </section>
  );
}
