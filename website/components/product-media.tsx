import { Reveal, RevealGroup, RevealItem } from "./reveal"
import { SectionHeader } from "./section"
import { marketingFor } from "../lib/marketing"
import type { Locale } from "../lib/locales"

export function ProductMedia({ locale }: { locale: Locale }) {
  const copy = marketingFor(locale).media
  return (
    <section id="walkthrough-demo" className="relative py-24 sm:py-32">
      <div className="wrap">
        <SectionHeader eyebrow={copy.eyebrow} title={copy.title} subtitle={copy.subtitle} />

        <Reveal className="mx-auto mt-12 max-w-5xl">
          <div className="overflow-hidden rounded-2xl border border-white/10 bg-ink-soft shadow-[0_34px_110px_-42px_rgba(0,0,0,0.85)]">
            <video
              className="aspect-[16/10] w-full bg-ink object-cover"
              controls
              playsInline
              preload="metadata"
              poster="/media/walkthrough-recording.png"
              aria-label={copy.videoLabel}
            >
              <source src="/media/syrus-product-screencast.webm" type="video/webm" />
              <source src="/media/syrus-product-screencast.mp4" type="video/mp4" />
              <track src="/media/syrus-product-screencast.vtt" kind="captions" srcLang="en" label={copy.captionLabel} default />
            </video>
          </div>
        </Reveal>

        <RevealGroup className="mt-8 grid gap-4 md:grid-cols-3" stagger={0.08}>
          {copy.shots.map((shot) => (
            <RevealItem key={shot.src}>
              <figure className="group overflow-hidden rounded-2xl border border-white/10 bg-white/[0.03] shadow-[0_24px_80px_-50px_rgba(0,0,0,0.8)]">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={shot.src}
                  alt={shot.alt}
                  width={1600}
                  height={1000}
                  loading="lazy"
                  className="block aspect-[16/10] w-full object-cover object-left-top transition-transform duration-500 group-hover:scale-[1.02]"
                />
                <figcaption className="border-t border-white/8 px-4 py-3 text-[0.86rem] font-medium text-cream-dim">{shot.title}</figcaption>
              </figure>
            </RevealItem>
          ))}
        </RevealGroup>
      </div>
    </section>
  )
}
