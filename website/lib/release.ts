// Desktop download metadata. The download links use GitHub's stable
// "latest release" permalinks, so they always resolve to the newest published
// release with no rebuild required. The version + file sizes here are for
// display only; they're baked from lib/release.json, which `npm run
// sync-release` refreshes from the GitHub API (the Pages workflow runs it on
// each release). If that refresh is skipped, the committed values are shown.

import data from "./release.json";

const REPO = "tkadauke/syrus";
const latestAsset = (name: string) =>
  `https://github.com/${REPO}/releases/latest/download/${name}`;

export type Platform = "mac";

export type DownloadArtifact = {
  id: Platform;
  osLabel: string;
  archLabel: string;
  filename: string;
  url: string;
  size: number | null;
};

export const releaseVersion: string | null = data.version || null;
export const allReleasesUrl = `https://github.com/${REPO}/releases`;

export const downloads: DownloadArtifact[] = [
  {
    id: "mac",
    osLabel: "macOS",
    archLabel: "Apple Silicon & Intel",
    filename: "Syrus.dmg",
    url: latestAsset("Syrus.dmg"),
    size: data.mac?.size ?? null,
  },
];

export function downloadFor(id: Platform): DownloadArtifact | undefined {
  return downloads.find((d) => d.id === id);
}

export function humanSize(bytes: number | null): string | null {
  if (!bytes) return null;
  return bytes >= 1024 ** 3
    ? `${(bytes / 1024 ** 3).toFixed(1)} GB`
    : `${Math.round(bytes / 1024 ** 2)} MB`;
}
