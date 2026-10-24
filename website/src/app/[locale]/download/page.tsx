import type { Metadata } from "next"
import { DownloadPage } from "@/components/pages/download-page"
import { localizedMetadata } from "@/lib/metadata"

export const metadata: Metadata = localizedMetadata({
  locale: "de",
  pathname: "/download",
  title: "Syrus herunterladen",
  description: "Lade die Syrus-Desktop-App für macOS auf Apple Silicon und Intel herunter.",
  availableLocales: ["en", "de"]
})

export default function GermanDownloadPage() {
  return <DownloadPage locale="de" />
}
