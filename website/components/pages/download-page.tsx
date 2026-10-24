import type { Metadata } from "next"
import { localizedMetadata } from "@/lib/metadata"
import { Nav } from "@/components/nav"
import { Footer } from "@/components/footer"
import { ButtonLink } from "@/components/button"
import { AppleIcon, DownloadIcon } from "@/components/icons"
import { downloads, humanSize, releaseVersion, allReleasesUrl, type DownloadArtifact, type Platform } from "@/lib/release"
import type { Locale } from "@/lib/locales"
import { localizedHref } from "@/lib/locales"
import { marketingFor } from "@/lib/marketing"

export const metadata: Metadata = localizedMetadata({
  locale: "en",
  pathname: "/download",
  title: "Download",
  description: "Download the Syrus desktop app for macOS (Apple Silicon & Intel).",
  availableLocales: ["en", "de"]
})

function PlatformIcon({ id }: { id: Platform }) {
  return id === "mac" ? <AppleIcon className="size-7 text-cream" /> : <DownloadIcon className="size-6 text-cream" />
}

function Card({ art, locale }: { art: DownloadArtifact; locale: Locale }) {
  const size = humanSize(art.size)
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

      <ButtonLink href={art.url} variant="primary" size="lg" className="w-full shrink-0 justify-center sm:w-auto">
        <DownloadIcon className="size-[18px]" />
        {marketingFor(locale).download.button}
      </ButtonLink>
    </article>
  )
}

export function DownloadPage({ locale }: { locale: Locale }) {
  const copy = marketingFor(locale).download
  return (
    <>
      <Nav locale={locale} />
      <main id="main" className="wrap max-w-2xl pt-32 pb-24">
        <a href={localizedHref("/", locale)} className="text-[0.85rem] text-cream-dim transition-colors hover:text-cream">
          {copy.back}
        </a>
        <h1 className="mt-6 text-balance text-4xl font-semibold tracking-tight text-cream">{copy.title}</h1>
        <p className="mt-4 text-pretty text-[1.02rem] leading-relaxed text-cream-dim">{copy.intro}</p>

        <div className="mt-10 grid gap-4">
          {downloads.map((art) => (
            <Card key={art.id} art={art} locale={locale} />
          ))}
        </div>

        <p className="mt-6 text-[0.85rem] text-cream-faint">
          {copy.latest}{" "}
          <a href={allReleasesUrl} className="text-clay underline underline-offset-2 hover:text-clay-bright">
            {copy.releases}
          </a>
        </p>
      </main>
      <Footer locale={locale} />
    </>
  )
}

export default function EnglishDownloadPage() {
  return <DownloadPage locale="en" />
}
