import { defineCollection } from "astro:content";
import { docsLoader } from "@astrojs/starlight/loaders";
import { docsSchema } from "@astrojs/starlight/schema";

export const collections = {
  docs: defineCollection({
    loader: docsLoader({
      generateId: ({ entry, data }) => {
        if (typeof data.slug === "string") return data.slug;

        const path = entry
          .replace(/\.(md|mdx|markdown|mdown|mkdn|mkd|mdwn)$/, "")
          .replace(/\/index$/, "");

        return `docs/${path}`;
      },
    }),
    schema: docsSchema(),
  }),
};
