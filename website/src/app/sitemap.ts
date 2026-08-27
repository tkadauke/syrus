import type { MetadataRoute } from "next";
import { allDocs } from "../../lib/docs";

// Metadata routes must be static under `output: "export"`.
export const dynamic = "force-static";

const BASE = "https://syrus-ai.dev";

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: `${BASE}/`, changeFrequency: "weekly", priority: 1 },
    { url: `${BASE}/download`, changeFrequency: "weekly", priority: 0.8 },
    ...allDocs().map((doc) => ({
      url: `${BASE}${doc.href}`,
      changeFrequency: "weekly" as const,
      priority: doc.slug ? 0.6 : 0.75,
    })),
  ];
}
