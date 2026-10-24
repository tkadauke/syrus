import type { Metadata } from "next"
import { ControlPlanePage } from "@/components/pages/control-plane-page"
import { localizedMetadata } from "@/lib/metadata"

export const metadata: Metadata = localizedMetadata({
  locale: "de",
  pathname: "/control-plane",
  title: "Steuerzentrale",
  description:
    "Syrus bildet die deterministische Steuerzentrale rund um Coding-Agenten: dauerhafte Jobs, begrenzte Zugangsdaten, Reviews, CI-Reparatur und Landeregeln.",
  availableLocales: ["en", "de"]
})

export default function GermanControlPlanePage() {
  return <ControlPlanePage locale="de" />
}
