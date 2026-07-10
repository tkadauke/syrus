import type { Metadata, Viewport } from "next";
import { MotionProvider } from "../../components/motion-provider";
import "./globals.css";

const description =
  "Syrus lets product, project, and application owners put AI to work from goal to merged pull request — conversations become tracked epics and tickets, AI does the heavy lifting, and a human review gates every merge. You ship more each sprint, with full visibility into what's built and what it cost.";

export const metadata: Metadata = {
  metadataBase: new URL("https://syrus-ai.dev"),
  title: {
    default: "Syrus — ship more of your roadmap, fully in control",
    template: "%s · Syrus",
  },
  description,
  applicationName: "Syrus",
  keywords: [
    "Syrus",
    "issue to PR automation",
    "coding agent harness",
    "self-hosted",
    "Claude Code",
    "Codex",
    "GitHub automation",
  ],
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    url: "https://syrus-ai.dev",
    siteName: "Syrus",
    title: "Syrus — ship more of your roadmap, fully in control",
    description,
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "Syrus — ship more of your roadmap, fully in control" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Syrus — ship more of your roadmap, fully in control",
    description,
    images: ["/og.png"],
  },
};

export const viewport: Viewport = {
  themeColor: "#14110d",
  colorScheme: "dark",
};

// Structured data for search engines: who runs this and what the product is.
const jsonLd = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Organization",
      "@id": "https://syrus-ai.dev/#org",
      name: "Syrus",
      url: "https://syrus-ai.dev",
      logo: "https://syrus-ai.dev/syrus-icon.png",
      email: "contact@syrus-ai.dev",
    },
    {
      "@type": "SoftwareApplication",
      name: "Syrus",
      url: "https://syrus-ai.dev",
      applicationCategory: "DeveloperApplication",
      operatingSystem:
        "macOS (universal: Apple Silicon & Intel), Windows (beta), self-hosted server (Docker/Kubernetes)",
      description,
      publisher: { "@id": "https://syrus-ai.dev/#org" },
    },
  ],
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
        <a
          href="#main"
          className="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70] focus:rounded-full focus:bg-clay focus:px-4 focus:py-2 focus:text-sm focus:font-semibold focus:text-on-accent"
        >
          Skip to content
        </a>
        <MotionProvider>{children}</MotionProvider>
      </body>
    </html>
  );
}
