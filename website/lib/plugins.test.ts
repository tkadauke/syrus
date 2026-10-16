import path from "node:path";
import { describe, expect, it } from "vitest";
import { metadataFromRegistration } from "./plugins";

describe("metadataFromRegistration", () => {
  it("reads DSL metadata from the plugin registration file and ignores spec decoys", () => {
    const pluginPath = path.join(import.meta.dirname, "__fixtures__", "plugin_with_spec_decoy");

    expect(metadataFromRegistration(pluginPath)).toEqual({
      displayName: "Fixture Plugin",
      category: "language",
      iconUrl: "/plugin-icons/fixture.svg",
    });
  });
});
