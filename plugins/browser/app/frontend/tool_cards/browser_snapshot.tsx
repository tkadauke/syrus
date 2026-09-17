import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserSnapshotToolCard: ToolCardRenderer = {
  toolName: "browser_snapshot",
  ...browserCardRenderer("snapshot")
}

export default browserSnapshotToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample. browser_snapshot returns a plain
// accessibility-tree dump, not JSON, so these use resultBody directly
// (parsedResult would stay null) -- the "large result" fixture the catalog's
// large-result coverage wants, and a realistic demonstration that a card can
// parse signal out of free text instead of a JSON envelope.
export const examples = [
  {
    id: "jobs_page_snapshot",
    label: "Accessibility tree for a Jobs list page (large result)",
    input: {},
    resultBody: [
      "Page URL: http://127.0.0.1:3001/jobs",
      "Page Title: Jobs · Syrus",
      "Page Snapshot:",
      "- generic [ref=e1]",
      "  - navigation [ref=e2]",
      "    - link \"Dashboard\" [ref=e3]",
      "    - link \"Jobs\" [ref=e4]",
      "    - link \"Epics\" [ref=e5]",
      "  - main [ref=e6]",
      "    - heading \"Jobs\" level=1 [ref=e7]",
      "    - table [ref=e8]",
      ...Array.from({ length: 20 }, (_, index) => `      - row \"JOB-${100 + index} · running\" [ref=e${9 + index}]`)
    ].join("\n")
  },
  {
    id: "no_signal_snapshot",
    label: "Malformed: no recognizable signal",
    description: "Plain text with none of the URL/Title/Snapshot markers the card looks for -- renderExpanded returns null so the generic fallback body renders instead.",
    resultBody: "(no accessible elements found)"
  }
]
