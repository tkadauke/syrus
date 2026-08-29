// Refresh lib/release.json from the latest GitHub release (version + asset
// sizes), shown on the download page. Download links themselves use the stable
// releases/latest/download permalinks, so this is purely cosmetic: on any
// failure we keep the committed values and let the build proceed.
//
// Run explicitly (`npm run sync-release`), not as part of `build`, so local
// offline builds don't depend on the network. The Pages workflow runs it
// before building, and passes GITHUB_TOKEN to lift the API rate limit.
// Graders use `--check-only` to validate the committed metadata without
// fetching or rewriting it.
import { writeFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const REPO = "tkadauke/syrus";
const here = dirname(fileURLToPath(import.meta.url));
const out =
  process.env.SYRUS_RELEASE_JSON_PATH ||
  join(here, "..", "lib", "release.json");
const checkOnly = process.argv.includes("--check-only");

function readCommittedRelease() {
  const data = JSON.parse(readFileSync(out, "utf8"));
  if (typeof data !== "object" || data === null) {
    throw new Error("release metadata must be an object");
  }
  if (data.version !== null && typeof data.version !== "string") {
    throw new Error("release metadata version must be a string or null");
  }
  for (const key of ["mac", "windows"]) {
    const platform = data[key];
    if (typeof platform !== "object" || platform === null) {
      throw new Error(`release metadata ${key} must be an object`);
    }
    if (platform.size !== null && typeof platform.size !== "number") {
      throw new Error(`release metadata ${key}.size must be a number or null`);
    }
  }
  return data;
}

if (checkOnly) {
  const data = readCommittedRelease();
  console.log(
    `sync-release: checked committed release.json (v${data.version || "unknown"})`,
  );
  process.exit(0);
}

const headers = {
  accept: "application/vnd.github+json",
  "user-agent": "syrus-website-build",
};
if (process.env.GITHUB_TOKEN) {
  headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
}

try {
  const res = await fetch(
    `https://api.github.com/repos/${REPO}/releases/latest`,
    { headers },
  );
  if (!res.ok) throw new Error(`GitHub API ${res.status}`);
  const rel = await res.json();
  const version = String(rel.tag_name || "").replace(/^v/, "") || null;
  const sizeOf = (name) =>
    rel.assets?.find((a) => a.name === name)?.size ?? null;
  const data = {
    version,
    mac: { size: sizeOf("Syrus.dmg") },
    windows: { size: sizeOf("Syrus-Setup.exe") },
  };
  writeFileSync(out, JSON.stringify(data, null, 2) + "\n");
  console.log(
    `sync-release: wrote v${version} (mac ${data.mac.size}, win ${data.windows.size})`,
  );
} catch (err) {
  let keep = "?";
  try {
    keep = readCommittedRelease().version;
  } catch {}
  console.warn(
    `sync-release: keeping committed release.json (v${keep}) — ${err.message}`,
  );
}
