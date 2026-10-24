import fs from "node:fs";
import path from "node:path";
import { renderMarkdown } from "./markdown";

export const blogCopy = {
  label: "Blog",
  description: "Notes from building Syrus: AI-native UX experiments, engineering deep dives, and what a fleet of coding agents teaches you.",
} as const;

export type BlogPost = {
  slug: string;
  href: string;
  title: string;
  description: string;
  date: string;
  body: string;
  html: string;
};

const BLOG_ROOT = path.join(process.cwd(), "src/content/blog");

function parseFrontmatter(raw: string): { attrs: Record<string, string>; body: string } {
  if (!raw.startsWith("---\n")) return { attrs: {}, body: raw };

  const end = raw.indexOf("\n---", 4);
  if (end === -1) return { attrs: {}, body: raw };

  const attrs: Record<string, string> = {};
  for (const line of raw.slice(4, end).split("\n")) {
    const match = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!match) continue;
    attrs[match[1]] = match[2].replace(/^["']|["']$/g, "");
  }

  return { attrs, body: raw.slice(end + 4).trimStart() };
}

function slugForFile(fileName: string): string {
  // Post files are named YYYY-MM-DD-<slug>.md; the date lives in the
  // front matter, so the URL slug drops the filename's date prefix.
  return fileName.replace(/\.md$/, "").replace(/^\d{4}-\d{2}-\d{2}-/, "");
}

function fallbackTitle(slug: string): string {
  return slug
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

export function allPosts(root: string = BLOG_ROOT): BlogPost[] {
  if (!fs.existsSync(root)) return [];

  const posts = fs
    .readdirSync(root)
    .filter((name) => name.endsWith(".md"))
    .map((name) => {
      const raw = fs.readFileSync(path.join(root, name), "utf8");
      const { attrs, body } = parseFrontmatter(raw);
      const slug = slugForFile(name);

      return {
        slug,
        href: `/blog/${slug}`,
        title: attrs.title || fallbackTitle(slug),
        description: attrs.description || "",
        date: attrs.date || "",
        body,
        html: renderMarkdown(body),
      };
    });

  // Newest first; slug breaks ties so the order is deterministic.
  return posts.sort((a, b) => b.date.localeCompare(a.date) || a.slug.localeCompare(b.slug));
}

export function findPost(slug: string, root: string = BLOG_ROOT): BlogPost | null {
  return allPosts(root).find((post) => post.slug === slug) || null;
}

export function blogStaticParams(): { slug: string }[] {
  return allPosts().map((post) => ({ slug: post.slug }));
}

export function formatPostDate(date: string): string {
  const parsed = new Date(`${date}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return date;
  return parsed.toLocaleDateString("en-US", {
    timeZone: "UTC",
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}
