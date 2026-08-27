import fs from "node:fs";
import path from "node:path";
import { renderMarkdown } from "./markdown";

export type PluginDoc = {
  slug: string;
  name: string;
  displayName: string;
  category: string;
  summary: string;
  description: string;
  href: string;
  iconUrl: string;
  sourceUrl: string;
  readme: string;
  html: string;
};

export type PluginDirectoryEntry = Omit<PluginDoc, "readme" | "html">;

const REPO_ROOT = path.resolve(process.cwd(), "..");
const PLUGINS_ROOT = path.join(REPO_ROOT, "plugins");
const WEBSITE_PUBLIC_ROOT = path.join(process.cwd(), "public");
const FALLBACK_ICON_URL = "/plugin-icons/spqr_eagle.svg";

function pluginDirs(): string[] {
  return fs
    .readdirSync(PLUGINS_ROOT, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
}

function readIfPresent(filePath: string): string | null {
  return fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8") : null;
}

function firstMatch(raw: string, pattern: RegExp): string | null {
  const match = raw.match(pattern);
  return match ? match[1].trim() : null;
}

function metadataFromRegistration(pluginPath: string) {
  const rubyFiles = walk(pluginPath).filter((file) => file.endsWith(".rb"));
  const raw = rubyFiles.map((file) => readIfPresent(file) || "").join("\n");

  return {
    displayName: firstMatch(raw, /display_name:\s*["']([^"']+)["']/),
    category: firstMatch(raw, /category:\s*["']([^"']+)["']/),
    iconUrl: firstMatch(raw, /icon_url:\s*["']([^"']+)["']/),
  };
}

function metadataFromGemspec(pluginPath: string) {
  const gemspecPath = fs.readdirSync(pluginPath).find((file) => file.endsWith(".gemspec"));
  const raw = gemspecPath ? readIfPresent(path.join(pluginPath, gemspecPath)) || "" : "";

  return {
    name: firstMatch(raw, /spec\.name\s*=\s*["']([^"']+)["']/),
    summary: firstMatch(raw, /spec\.summary\s*=\s*["']([^"']+)["']/),
  };
}

function walk(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(dir, entry.name);
    if (entry.isDirectory()) return walk(entryPath);
    if (entry.isFile()) return [entryPath];
    return [];
  });
}

function titleize(value: string): string {
  return value
    .replace(/^syrus[-_]/, "Syrus ")
    .split(/[-_]/)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function parseReadme(raw: string, fallbackTitle: string) {
  const title = firstMatch(raw, /^#\s+(.+)$/m) || fallbackTitle;
  const bodyWithoutTitle = raw.replace(/^#\s+.+\n+/, "").trimStart();
  const paragraphs: string[] = [];

  for (const block of bodyWithoutTitle.split(/\n{2,}/)) {
    const trimmed = block.trim();
    if (!trimmed) continue;
    if (trimmed.startsWith("#")) break;
    if (/^[-*]\s+/m.test(trimmed) || /^\d+\.\s+/m.test(trimmed)) continue;
    paragraphs.push(trimmed.replace(/\n/g, " "));
    if (paragraphs.length === 2) break;
  }

  return {
    title,
    description: paragraphs.join("\n\n"),
  };
}

function iconFor(slug: string, gemName: string | null, registrationIcon: string | null): string {
  const candidates = [
    registrationIcon,
    `/plugin-icons/${slug}.svg`,
    gemName ? `/plugin-icons/${gemName}.svg` : null,
    gemName ? `/plugin-icons/${gemName.replaceAll("_", "-")}.svg` : null,
  ].filter(Boolean) as string[];

  return candidates.find((candidate) => fs.existsSync(path.join(WEBSITE_PUBLIC_ROOT, candidate))) || FALLBACK_ICON_URL;
}

export function allPlugins(): PluginDoc[] {
  return pluginDirs().map((slug) => {
    const pluginPath = path.join(PLUGINS_ROOT, slug);
    const gemspec = metadataFromGemspec(pluginPath);
    const registration = metadataFromRegistration(pluginPath);
    const readme = readIfPresent(path.join(pluginPath, "README.md")) || `# ${titleize(slug)}\n\nDocumentation is not available yet.`;
    const parsed = parseReadme(readme, registration.displayName || gemspec.name || titleize(slug));
    const displayName = registration.displayName || parsed.title || titleize(slug);
    const summary = gemspec.summary || parsed.description.split("\n\n")[0] || "";

    return {
      slug,
      name: gemspec.name || slug,
      displayName,
      category: registration.category || "uncategorized",
      summary,
      description: parsed.description || summary,
      href: `/plugins/${slug}`,
      iconUrl: iconFor(slug, gemspec.name, registration.iconUrl),
      sourceUrl: `https://github.com/tkadauke/syrus/tree/main/plugins/${slug}`,
      readme,
      html: renderMarkdown(readme),
    };
  });
}

export function pluginDirectoryEntries(): PluginDirectoryEntry[] {
  return allPlugins().map(({ readme: _readme, html: _html, ...plugin }) => plugin);
}

export function findPlugin(slug: string): PluginDoc | null {
  return allPlugins().find((plugin) => plugin.slug === slug) || null;
}

export function pluginStaticParams(): { slug: string }[] {
  return allPlugins().map((plugin) => ({ slug: plugin.slug }));
}
