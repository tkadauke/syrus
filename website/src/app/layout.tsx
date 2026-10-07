import type { Metadata, Viewport } from "next"
import { MotionProvider } from "../../components/motion-provider"
import "./globals.css"

const description =
  "Syrus is an open-source, self-hosted automation harness for developers: turn issues, chats, and video walkthroughs into tracked pull requests while keeping your repos, checks, review policy, and merge queue under your control."

export const metadata: Metadata = {
  metadataBase: new URL("https://syrus-ai.dev"),
  title: {
    default: "Syrus — self-hosted AI coding agents for developers",
    template: "%s · Syrus"
  },
  description,
  applicationName: "Syrus",
  keywords: ["Syrus", "issue to PR automation", "coding agent harness", "self-hosted", "Claude Code", "Codex", "GitHub automation"],
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    url: "https://syrus-ai.dev",
    siteName: "Syrus",
    title: "Syrus — self-hosted AI coding agents for developers",
    description,
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "Syrus — self-hosted AI coding agents for developers" }]
  },
  twitter: {
    card: "summary_large_image",
    title: "Syrus — self-hosted AI coding agents for developers",
    description,
    images: ["/og.png"]
  }
}

export const viewport: Viewport = {
  themeColor: "#14110d",
  colorScheme: "dark"
}

// Structured data for search engines: a public open-source project and its app.
const jsonLd = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "SoftwareSourceCode",
      "@id": "https://syrus-ai.dev/#source",
      name: "Syrus",
      url: "https://syrus-ai.dev",
      codeRepository: "https://github.com/tkadauke/syrus",
      license: "https://github.com/tkadauke/syrus/blob/main/LICENSE",
      programmingLanguage: ["Ruby", "TypeScript", "Go"]
    },
    {
      "@type": "SoftwareApplication",
      name: "Syrus",
      url: "https://syrus-ai.dev",
      applicationCategory: "DeveloperApplication",
      operatingSystem: "macOS (universal: Apple Silicon & Intel), self-hosted server (Docker/Kubernetes)",
      description,
      isAccessibleForFree: true,
      license: "https://github.com/tkadauke/syrus/blob/main/LICENSE",
      softwareSourceCode: { "@id": "https://syrus-ai.dev/#source" }
    }
  ]
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
        <a
          href="#main"
          className="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70] focus:rounded-full focus:bg-clay focus:px-4 focus:py-2 focus:text-sm focus:font-semibold focus:text-on-accent"
        >
          Skip to content
        </a>
        <MotionProvider>{children}</MotionProvider>
      </body>
    </html>
  )
}
