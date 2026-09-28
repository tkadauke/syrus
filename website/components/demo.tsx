"use client";

import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { ButtonLink } from "./button";
import { DownloadCTA } from "./download-cta";
import { ArrowRight, CheckIcon } from "./icons";
import { Reveal } from "./reveal";
import { infraPoints, site } from "../lib/site";

type Status = "idle" | "loading" | "success" | "error" | "mailto";

const inputClass =
  "w-full rounded-lg border border-white/10 bg-white/[0.03] px-3.5 py-2.5 text-[0.92rem] text-cream placeholder:text-cream-faint transition-colors focus:border-clay/50 focus:bg-white/[0.05] focus:outline-none";

export function Demo() {
  const [status, setStatus] = useState<Status>("idle");
  const [error, setError] = useState<string>("");
  const successRef = useRef<HTMLHeadingElement>(null);

  // On success the form unmounts — move focus to the confirmation so keyboard
  // and screen-reader users aren't silently dropped to <body>.
  useEffect(() => {
    if (status === "success") successRef.current?.focus();
  }, [status]);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const data = new FormData(form);

    // Honeypot — bail silently if a bot filled it.
    if (data.get("botcheck")) return;

    const name = String(data.get("name") || "");
    const email = String(data.get("email") || "");
    const company = String(data.get("company") || "");
    const message = String(data.get("message") || "");

    const mailtoFallback = () => {
      const b = encodeURIComponent(
        `Name: ${name}\nCompany: ${company}\nEmail: ${email}\n\n${message}`,
      );
      window.location.href = `mailto:${site.contactEmail}?subject=${encodeURIComponent(
        "Syrus guided setup request",
      )}&body=${b}`;
      setStatus("mailto");
    };

    setStatus("loading");
    setError("");
    try {
      // Cross-origin to the self-hosted SMTP endpoint (the apex is now static
      // Pages). On any network/CORS failure the catch below opens a mailto.
      const res = await fetch(`${site.apiBase}/api/demo`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, email, company, message }),
      });
      const json = await res.json().catch(() => ({}));
      if (res.ok && json.success) {
        setStatus("success");
      } else if (res.status === 422) {
        setStatus("error");
        setError(json.error || "Please check your details and try again.");
      } else {
        // Not configured (503) or a send failure (502) → prefilled email.
        mailtoFallback();
      }
    } catch {
      mailtoFallback();
    }
  }

  return (
    <section id="demo" className="relative overflow-hidden py-24 sm:py-32">
      {/* warm glow behind the band */}
      <div aria-hidden className="pointer-events-none absolute inset-0 -z-0">
        <div
          className="aurora left-1/2 top-1/2 h-[420px] w-[820px] -translate-x-1/2 -translate-y-1/2 opacity-40"
          style={{
            background:
              "radial-gradient(closest-side, var(--aurora-a), transparent)",
          }}
        />
      </div>

      <div className="wrap relative z-10">
        <Reveal className="mx-auto max-w-6xl">
          <div className="grid overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-b from-ink-soft to-ink lg:grid-cols-2">
            {/* download + guided help */}
            <div className="border-b border-white/8 p-8 sm:p-11 lg:border-b-0 lg:border-r">
              <h2 className="text-balance text-3xl font-semibold leading-[1.08] tracking-[-0.02em] text-cream sm:text-4xl">
                Run Syrus yourself, or get{" "}
                <span className="clay-text">a guided setup.</span>
              </h2>
              <p className="mt-4 text-[1rem] leading-relaxed text-cream-dim">
                Download the desktop app — it sets up a complete local Syrus
                (Docker included) or connects to your team&apos;s instance. If
                you want help mapping Syrus onto your repos, checks, and review
                policy, send a note and we&apos;ll walk through it with you.
              </p>
              <p className="mt-3 text-[0.9rem] text-cream-faint">
                The product video above shows the core loop first: walkthrough
                to Job, implementation, review, and tracked cost.
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
                  <li
                    key={p}
                    className="flex items-start gap-2.5 text-[0.9rem] text-cream-dim"
                  >
                    <CheckIcon className="mt-0.5 size-4 shrink-0 text-clay" />
                    {p}
                  </li>
                ))}
              </ul>
            </div>

            {/* secondary contact form */}
            <div className="p-8 sm:p-11">
              {status === "success" ? (
                <div
                  role="status"
                  className="flex h-full min-h-[320px] flex-col items-center justify-center text-center"
                >
                  <span className="flex size-14 items-center justify-center rounded-full clay-gradient text-on-accent">
                    <CheckIcon className="size-7" />
                  </span>
                  <h3
                    ref={successRef}
                    tabIndex={-1}
                    className="mt-5 text-xl font-semibold text-cream outline-none"
                  >
                    Request received
                  </h3>
                  <p className="mt-2 max-w-xs text-[0.92rem] text-cream-dim">
                    Thanks — we&apos;ll be in touch shortly to set up your Syrus
                    walkthrough.
                  </p>
                </div>
              ) : (
                <form onSubmit={onSubmit} className="grid gap-4">
                  <div>
                    <p className="font-mono text-[0.72rem] uppercase tracking-[0.18em] text-clay">
                      Guided help
                    </p>
                    <h3 className="mt-2 text-xl font-semibold text-cream">
                      Tell us what you want to run
                    </h3>
                  </div>

                  {/* honeypot */}
                  <input
                    type="checkbox"
                    name="botcheck"
                    tabIndex={-1}
                    autoComplete="off"
                    className="hidden"
                    aria-hidden
                  />

                  <div className="grid gap-4 sm:grid-cols-2">
                    <label className="grid gap-1.5">
                      <span className="text-[0.8rem] text-cream-dim">Name</span>
                      <input
                        name="name"
                        required
                        autoComplete="name"
                        placeholder="Ada Lovelace"
                        className={inputClass}
                      />
                    </label>
                    <label className="grid gap-1.5">
                      <span className="text-[0.8rem] text-cream-dim">Company</span>
                      <input
                        name="company"
                        autoComplete="organization"
                        placeholder="Acme Inc."
                        className={inputClass}
                      />
                    </label>
                  </div>

                  <label className="grid gap-1.5">
                    <span className="text-[0.8rem] text-cream-dim">Work email</span>
                    <input
                      name="email"
                      type="email"
                      required
                      autoComplete="email"
                      placeholder="ada@acme.com"
                      className={inputClass}
                    />
                  </label>

                  <label className="grid gap-1.5">
                    <span className="text-[0.8rem] text-cream-dim">
                      What would you like help with?
                    </span>
                    <textarea
                      name="message"
                      rows={3}
                      placeholder="We want agents handling dependency bumps and CI repairs across ~20 repos…"
                      className={`${inputClass} resize-none`}
                    />
                  </label>

                  <div role="status" aria-live="polite">
                    {status === "error" && (
                      <p className="text-[0.85rem] text-[#f0806a]">{error}</p>
                    )}
                    {status === "mailto" && (
                      <p className="text-[0.85rem] text-cream-dim">
                        Opening your email client… if nothing happens, email{" "}
                        <a
                          className="text-clay underline underline-offset-2"
                          href={`mailto:${site.contactEmail}`}
                        >
                          {site.contactEmail}
                        </a>
                        .
                      </p>
                    )}
                  </div>

                  <button
                    type="submit"
                    disabled={status === "loading"}
                    className="group mt-1 inline-flex h-12 items-center justify-center gap-2.5 rounded-full clay-gradient px-5 text-[0.95rem] font-semibold text-on-accent transition-all duration-200 hover:-translate-y-0.5 hover:brightness-[1.06] disabled:cursor-not-allowed disabled:opacity-70"
                  >
                    {status === "loading" ? "Sending…" : "Request guided help"}
                    {status !== "loading" && (
                      <ArrowRight className="size-4 transition-transform duration-200 group-hover:translate-x-0.5" />
                    )}
                  </button>
                  <p className="text-center text-[0.75rem] text-cream-faint">
                    No spam. We only use this to arrange a guided walkthrough.
                  </p>
                </form>
              )}
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
