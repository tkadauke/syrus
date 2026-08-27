import fs from "node:fs";
import path from "node:path";
import { renderMarkdown } from "./markdown";

export type DocPage = {
  slug: string;
  href: string;
  title: string;
  description: string;
  body: string;
  html: string;
};

const DOCS_ROOT = path.join(process.cwd(), "src/content/docs");

const preferredOrder = [
  "",
  "what-is-syrus",
  "why-use-syrus",
  "getting-started",
  "concepts",
  "workflows",
  "landing",
  "tests-and-graders",
  "previews",
  "collaboration",
  "features",
  "configuration",
  "plugins",
  "cli",
  "desktop",
  "deployment",
  "deployment/docker-compose",
  "deployment/kubernetes",
  "scheduling-and-recovery",
  "observability",
  "recipes",
  "troubleshooting",
  "faq",
  "architecture",
  "api",
];

function walk(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(dir, entry.name);
    if (entry.isDirectory()) return walk(entryPath);
    if (entry.isFile() && entry.name.endsWith(".md")) return [entryPath];
    return [];
  });
}

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

function slugForFile(filePath: string): string {
  const relative = path.relative(DOCS_ROOT, filePath).replace(/\.md$/, "");
  return relative === "index" || relative.endsWith("/index")
    ? relative.replace(/\/?index$/, "")
    : relative;
}

function hrefForSlug(slug: string): string {
  return slug ? `/docs/${slug}` : "/docs";
}

function fallbackTitle(slug: string): string {
  if (!slug) return "Syrus Docs";
  return slug
    .split("/")
    .at(-1)!
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

export function allDocs(): DocPage[] {
  const docs = walk(DOCS_ROOT).map((filePath) => {
    const raw = fs.readFileSync(filePath, "utf8");
    const { attrs, body } = parseFrontmatter(raw);
    const slug = slugForFile(filePath);

    return {
      slug,
      href: hrefForSlug(slug),
      title: attrs.title || fallbackTitle(slug),
      description: attrs.description || "",
      body,
      html: renderMarkdown(body),
    };
  });

  return docs.sort((a, b) => {
    const aIndex = preferredOrder.indexOf(a.slug);
    const bIndex = preferredOrder.indexOf(b.slug);
    if (aIndex !== -1 || bIndex !== -1) {
      return (aIndex === -1 ? Number.MAX_SAFE_INTEGER : aIndex) -
        (bIndex === -1 ? Number.MAX_SAFE_INTEGER : bIndex);
    }

    return a.slug.localeCompare(b.slug);
  });
}

export function findDoc(slugParts: string[] = []): DocPage | null {
  const slug = slugParts.join("/");
  return allDocs().find((doc) => doc.slug === slug) || null;
}

export function docsStaticParams(): { slug: string[] }[] {
  return allDocs()
    .filter((doc) => doc.slug)
    .map((doc) => ({ slug: doc.slug.split("/") }));
}
