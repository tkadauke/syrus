import type { Metadata } from "next"
import { HomePage } from "@/components/pages/home-page"
import { localizedMetadata } from "@/lib/metadata"

export const metadata: Metadata = localizedMetadata({
  locale: "de",
  pathname: "/",
  title: "Syrus — selbst gehostete KI-Coding-Agenten für Entwickler",
  description:
    "Syrus automatisiert den Weg von Issues, Chats und Videoanleitungen zu nachvollziehbaren Pull Requests — selbst gehostet und unter Ihrer Kontrolle.",
  availableLocales: ["en", "de"],
  absoluteTitle: true
})

export default function GermanHomePage() {
  return <HomePage locale="de" />
}
