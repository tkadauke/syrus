import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  site: "https://syrusai.dev",
  integrations: [
    starlight({
      title: "Syrus",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/tkadauke/syrus",
        },
      ],
      sidebar: [
        {
          label: "Start here",
          items: [
            { label: "Getting started", slug: "docs/getting-started" },
            { label: "Concepts", slug: "docs/concepts" },
            { label: "Deployment", slug: "docs/deployment" },
          ],
        },
        {
          label: "Reference",
          items: [{ autogenerate: { directory: "." } }],
        },
      ],
    }),
  ],
});
