import { Reveal, RevealGroup, RevealItem } from "./reveal";
import { SectionHeader } from "./section";

const screenshots = [
  {
    src: "/media/chat-proposal.png",
    title: "Chat to proposed Job",
    alt: "A Syrus chat drafting a proposal card for a Job, with the repository file tree and config open alongside.",
  },
  {
    src: "/media/in-progress-jobs.png",
    title: "In-progress jobs",
    alt: "A Syrus dashboard list of in-progress Jobs showing workflow status, filters, and review state.",
  },
] as const;

export function ProductMedia() {
  return (
    <section id="walkthrough-demo" className="relative py-24 sm:py-32">
      <div className="wrap">
        <SectionHeader
          eyebrow="Product demo"
          title="A narrated screen recording can become the next reviewed PR."
          subtitle="The launch walkthrough centers on the video-to-Job flow, then follows that work through tracked execution and review queues."
        />

        <Reveal className="mx-auto mt-12 max-w-5xl">
          <div className="overflow-hidden rounded-2xl border border-white/10 bg-ink-soft shadow-[0_34px_110px_-42px_rgba(0,0,0,0.85)]">
            <video
              className="aspect-[16/10] w-full bg-ink object-cover"
              controls
              playsInline
              preload="metadata"
              poster="/product-screenshot.png"
              aria-label="Syrus product screencast showing a video walkthrough becoming a tracked Job."
            >
              <source
                src="/media/syrus-product-screencast.webm"
                type="video/webm"
              />
              <source
                src="/media/syrus-product-screencast.mp4"
                type="video/mp4"
              />
              <track
                src="/media/syrus-product-screencast.vtt"
                kind="captions"
                srcLang="en"
                label="English"
                default
              />
            </video>
          </div>
        </Reveal>

        <RevealGroup
          className="mx-auto mt-8 grid max-w-5xl gap-4 md:grid-cols-2"
          stagger={0.08}
        >
          {screenshots.map((shot) => (
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
                <figcaption className="border-t border-white/8 px-4 py-3 text-[0.86rem] font-medium text-cream-dim">
                  {shot.title}
                </figcaption>
              </figure>
            </RevealItem>
          ))}
        </RevealGroup>
      </div>
    </section>
  );
}
