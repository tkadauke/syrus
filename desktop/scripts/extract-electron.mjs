import { spawnSync } from "node:child_process";
import extractZip from "@electron-internal/extract-zip";

export async function extractElectronZip(
  artifactPath,
  distPath,
  { runUnzip = spawnSync, extract = extractZip } = {},
) {
  const unzip = runUnzip("unzip", ["-q", artifactPath, "-d", distPath], {
    stdio: "inherit",
  });

  if (unzip.status === 0) return;

  await extract(artifactPath, { dir: distPath });
}
