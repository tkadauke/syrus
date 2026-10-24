/* The product shot. `desktopSrc` / `mobileSrc` are resolved on the server (see
   app/page.tsx) by checking which public/product-screenshot* files exist —
   deterministic, no hydration race. Art-directed: a browser-chrome frame with
   the wide shot on >= sm, a phone frame with the tall shot on mobile. If no
   image is present, a convincing mock of the Syrus Jobs dashboard is shown so
   the hero never looks empty. */

import { marketingFor } from "../lib/marketing"
import type { Locale } from "../lib/locales"

const toneStyles: Record<string, string> = {
  active: "bg-[#c96f4a]/15 text-[#e28a5c] ring-[#c96f4a]/30",
  pr: "bg-[#5b8bd0]/12 text-[#87aede] ring-[#5b8bd0]/25",
  done: "bg-[#5fa86a]/12 text-[#84c78d] ring-[#5fa86a]/25",
  idle: "bg-white/6 text-cream-dim ring-white/10"
}

const dotColor: Record<string, string> = {
  active: "#e28a5c",
  pr: "#87aede",
  done: "#84c78d",
  idle: "#8a7f6d"
}

function Placeholder({ locale }: { locale: Locale }) {
  const copy = marketingFor(locale).screenshot
  // A decorative mock, not real data — present it to AT as a single image.
  return (
    <div role="img" aria-label={copy.dashboardLabel} className="flex h-full flex-col bg-gradient-to-b from-[#161009] to-[#120e09]">
      <div aria-hidden="true" className="contents">
        <div className="flex items-center justify-between border-b border-white/6 px-5 py-3.5">
          <div className="flex items-center gap-2.5">
            <span className="text-[0.9rem] font-semibold text-cream">{copy.jobsLabel}</span>
            <span className="rounded-full bg-white/6 px-2 py-0.5 font-mono text-[0.68rem] text-cream-dim">acme/web</span>
          </div>
          <div className="flex items-center gap-2">
            <div className="h-6 w-36 rounded-md bg-white/5" />
            <div className="size-6 rounded-full clay-gradient" />
          </div>
        </div>

        <div className="flex-1 divide-y divide-white/5 overflow-hidden">
          {copy.jobs.map((j) => (
            <div key={j.id} className="flex items-center gap-4 px-5 py-[0.85rem] transition-colors hover:bg-white/[0.02]">
              <span className="size-2 shrink-0 rounded-full" style={{ background: dotColor[j.tone] }} />
              <span className="hidden w-10 shrink-0 font-mono text-[0.72rem] text-cream-faint sm:block">{j.id}</span>
              <div className="min-w-0 flex-1">
                <p className="truncate text-[0.82rem] font-medium text-cream">{j.title}</p>
                <p className="truncate font-mono text-[0.68rem] text-cream-faint">{j.meta}</p>
              </div>
              <span className={`shrink-0 rounded-full px-2.5 py-1 text-[0.68rem] font-medium ring-1 ring-inset ${toneStyles[j.tone]}`}>{j.state}</span>
            </div>
          ))}
        </div>

        <div className="pointer-events-none flex items-center gap-1.5 border-t border-white/6 px-5 py-2.5 font-mono text-[0.65rem] text-cream-faint">
          <span className="size-1.5 rounded-full bg-[#84c78d]" />
          {copy.status}
        </div>
      </div>
    </div>
  )
}

function BrowserFrame({ src, locale }: { src: string | null; locale: Locale }) {
  const copy = marketingFor(locale).screenshot
  // Bare screenshot — no window chrome, no bezel. Just rounded corners + shadow.
  return (
    <div className="overflow-hidden rounded-2xl shadow-[0_40px_120px_-30px_rgba(0,0,0,0.85)]">
      {src ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={src} alt={copy.desktopAlt} width={956} height={528} className="block h-auto w-full" />
      ) : (
        <div className="aspect-[16/10] w-full">
          <Placeholder locale={locale} />
        </div>
      )}
    </div>
  )
}

function PhoneFrame({ src, locale }: { src: string; locale: Locale }) {
  return (
    <div className="mx-auto w-full max-w-[268px]">
      <div className="relative rounded-[2.4rem] bg-gradient-to-b from-white/12 to-white/[0.03] p-[2px] shadow-[0_30px_90px_-30px_rgba(0,0,0,0.85)]">
        <div className="rounded-[2.3rem] border border-white/10 bg-ink-soft p-1.5">
          <div className="relative overflow-hidden rounded-[1.9rem]">
            <span className="absolute left-1/2 top-2 z-10 h-1.5 w-16 -translate-x-1/2 rounded-full bg-black/45" />
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={src}
              alt={marketingFor(locale).screenshot.mobileAlt}
              width={471}
              height={1024}
              className="block aspect-[471/1024] w-full object-cover object-top"
            />
          </div>
        </div>
      </div>
    </div>
  )
}

export function ScreenshotFrame({ desktopSrc = null, mobileSrc = null, locale }: { desktopSrc?: string | null; mobileSrc?: string | null; locale: Locale }) {
  return (
    <>
      <div className={mobileSrc ? "hidden sm:block" : "block"}>
        <BrowserFrame src={desktopSrc} locale={locale} />
      </div>
      {mobileSrc && (
        <div className="sm:hidden">
          <PhoneFrame src={mobileSrc} locale={locale} />
        </div>
      )}
    </>
  )
}
