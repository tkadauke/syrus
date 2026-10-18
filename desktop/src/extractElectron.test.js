import { describe, expect, it, vi } from "vitest";
import { extractElectronZip } from "../scripts/extract-electron.mjs";

describe("Electron archive extraction", () => {
  it("uses the declared extractor when the host has no unzip executable", async () => {
    const runUnzip = vi.fn(() => ({ error: new Error("spawn unzip ENOENT"), status: null }));
    const extract = vi.fn().mockResolvedValue(undefined);

    await extractElectronZip("/cache/electron.zip", "/app/electron/dist", {
      runUnzip,
      extract,
    });

    expect(runUnzip).toHaveBeenCalledWith(
      "unzip",
      ["-q", "/cache/electron.zip", "-d", "/app/electron/dist"],
      { stdio: "inherit" },
    );
    expect(extract).toHaveBeenCalledWith("/cache/electron.zip", {
      dir: "/app/electron/dist",
    });
  });

  it("does not load the fallback after system unzip succeeds", async () => {
    const extract = vi.fn();

    await extractElectronZip("/cache/electron.zip", "/app/electron/dist", {
      runUnzip: () => ({ status: 0 }),
      extract,
    });

    expect(extract).not.toHaveBeenCalled();
  });
});
