// Copy plugin icons from the Rails app's canonical public/plugin-icons folder
// into the website public directory before Next builds or starts dev mode.
import { copyFileSync, existsSync, mkdirSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");
const sourceDir = join(repoRoot, "public", "plugin-icons");
const targetDir = join(repoRoot, "website", "public", "plugin-icons");

if (!existsSync(sourceDir)) {
  throw new Error(`plugin icon source directory does not exist: ${sourceDir}`);
}

mkdirSync(targetDir, { recursive: true });

for (const entry of readdirSync(targetDir)) {
  if (entry.endsWith(".svg")) {
    unlinkSync(join(targetDir, entry));
  }
}

const icons = readdirSync(sourceDir)
  .filter((entry) => entry.endsWith(".svg"))
  .sort();

for (const icon of icons) {
  copyFileSync(join(sourceDir, icon), join(targetDir, icon));
}

writeFileSync(join(targetDir, ".gitignore"), "*\n!.gitignore\n");

console.log(`sync-plugin-icons: copied ${icons.length} icons`);
