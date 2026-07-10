import type { MetadataRoute } from "next";

// Metadata routes must be static under `output: "export"`.
export const dynamic = "force-static";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: "*", allow: "/" },
    sitemap: "https://syrus-ai.dev/sitemap.xml",
  };
}
