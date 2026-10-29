import path from "node:path"
import fs from "node:fs"
import os from "node:os"
import React from "react"
import { renderToStaticMarkup } from "react-dom/server"
import { afterEach, describe, expect, it } from "vitest"
import { PluginDocumentation } from "../components/plugin-documentation"
import { metadataFromRegistration, pluginDocuments } from "./plugins"

const temporaryDirectories: string[] = []

afterEach(() => {
  temporaryDirectories.splice(0).forEach((directory) => fs.rmSync(directory, { recursive: true, force: true }))
})

function pluginFixture(documents: Record<string, string>): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "syrus-plugin-docs-"))
  temporaryDirectories.push(root)
  const docs = path.join(root, "docs", "syrus_docs")
  fs.mkdirSync(docs, { recursive: true })
  Object.entries(documents).forEach(([name, content]) => fs.writeFileSync(path.join(docs, name), content))
  return root
}

describe("metadataFromRegistration", () => {
  it("reads DSL metadata from the plugin registration file and ignores spec decoys", () => {
    const pluginPath = path.join(import.meta.dirname, "__fixtures__", "plugin_with_spec_decoy")

    expect(metadataFromRegistration(pluginPath)).toEqual({
      displayName: "Fixture Plugin",
      category: "language",
      iconUrl: "/plugin-icons/fixture.svg"
    })
  })
})

describe("pluginDocuments", () => {
  it("loads a single canonical document", () => {
    const pluginPath = pluginFixture({ "widgets.md": "# Widget guide\n\nHello." })

    const documents = pluginDocuments(pluginPath, "widgets")
    expect(documents).toEqual([expect.objectContaining({ slug: "widgets", title: "Widget guide", primary: true })])

    const rendered = renderToStaticMarkup(React.createElement(PluginDocumentation, { documents }))
    expect(rendered).toContain('id="doc-widgets"')
    expect(rendered).toContain("Widget guide")
    expect(rendered).not.toContain("Plugin documentation")
  })

  it("prefers the plugin-named document and preserves every other document deterministically", () => {
    const pluginPath = pluginFixture({
      "zebra.md": "# Zebra reference",
      "widgets.md": "# Widget overview",
      "alpha.md": "# Alpha reference"
    })

    const documents = pluginDocuments(pluginPath, "widgets")
    expect(documents.map(({ slug, primary }) => [slug, primary])).toEqual([
      ["widgets", true],
      ["alpha", false],
      ["zebra", false]
    ])

    const rendered = renderToStaticMarkup(React.createElement(PluginDocumentation, { documents }))
    expect(rendered).toContain('aria-label="Plugin documentation"')
    expect(rendered).toContain('href="#doc-alpha"')
    expect(rendered).toContain('href="#doc-zebra"')
    expect(rendered).toContain("Alpha reference")
    expect(rendered).toContain("Zebra reference")
  })

  it("fails when canonical documentation is missing", () => {
    const pluginPath = pluginFixture({})

    expect(() => pluginDocuments(pluginPath, "widgets")).toThrow(/no canonical documentation/)
  })
})
