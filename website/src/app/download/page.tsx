import type { Metadata } from "next";
import { Nav } from "../../../components/nav";
import { Footer } from "../../../components/footer";
import { ButtonLink } from "../../../components/button";
import { AppleIcon, WindowsIcon, DownloadIcon } from "../../../components/icons";
import {
  downloads,
  humanSize,
  releaseVersion,
  allReleasesUrl,
  type DownloadArtifact,
  type Platform,
} from "../../../lib/release";

export const metadata: Metadata = {
  title: "Download",
  description:
    "Download the Syrus desktop app for macOS (Apple Silicon & Intel) and Windows.",
  alternates: { canonical: "/download" },
};

function PlatformIcon({ id }: { id: Platform }) {
  return id === "mac" ? (
    <AppleIcon className="size-7 text-cream" />
  ) : (
    <WindowsIcon className="size-6 text-cream" />
  );
}

function Card({ art }: { art: DownloadArtifact }) {
  const size = humanSize(art.size);
  return (
    <article className="card flex min-w-0 flex-wrap items-center gap-4 p-5 sm:flex-nowrap sm:gap-5 sm:p-6">
      <span className="flex size-12 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-white/[0.03] sm:size-14">
        <PlatformIcon id={art.id} />
      </span>

      <div className="min-w-0 flex-1 basis-0">
        <h2 className="text-lg font-semibold text-cream">{art.osLabel}</h2>
        <p className="mt-0.5 text-[0.9rem] text-cream-dim">
          {art.archLabel}
          {releaseVersion ? ` · v${releaseVersion}` : ""}
          {size ? ` · ${size}` : ""}
        </p>
      </div>

      <ButtonLink
        href={art.url}
        variant="primary"
        size="lg"
        className="w-full shrink-0 justify-center sm:w-auto"
      >
        <DownloadIcon className="size-[18px]" />
        Download
      </ButtonLink>
    </article>
  );
}

export default function DownloadPage() {
  return (
    <>
      <Nav />
      <main id="main" className="wrap max-w-2xl pt-32 pb-24">
        <a
          href="/"
          className="text-[0.85rem] text-cream-dim transition-colors hover:text-cream"
        >
          ← Back to home
        </a>
        <h1 className="mt-6 text-balance text-4xl font-semibold tracking-tight text-cream">
          Download Syrus
        </h1>
        <p className="mt-4 text-pretty text-[1.02rem] leading-relaxed text-cream-dim">
          The Syrus desktop app for macOS and Windows — it sets up a complete
          local Syrus (Docker included) or connects to your team&apos;s
          instance. The macOS build is universal: one download runs natively on
          both Apple&nbsp;Silicon and Intel Macs.
        </p>

        <div className="mt-10 grid gap-4">
          {downloads.map((art) => (
            <Card key={art.id} art={art} />
          ))}
        </div>

        <p className="mt-6 text-[0.85rem] text-cream-faint">
          Every download is the latest published release. Looking for a specific
          version or the release notes?{" "}
          <a
            href={allReleasesUrl}
            className="text-clay underline underline-offset-2 hover:text-clay-bright"
          >
            Browse all releases →
          </a>
        </p>
        <p className="mt-4 text-[0.85rem] text-cream-faint">
          The Windows build is in beta and not yet code-signed — expect a
          SmartScreen prompt on first run. Prefer the terminal? Syrus also
          ships a CLI for macOS and Linux.
        </p>
      </main>
      <Footer />
    </>
  );
}
