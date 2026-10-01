import { fireEvent, render, screen } from "@testing-library/react"
import type { ComponentProps } from "react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { EntityReference, entityReferenceHref, entityReferenceLabel, Row } from "./toolCardUi"

describe("toolCardUi Row", () => {
  it("stays self-contained for direct CardShell usage", () => {
    render(<Row label="Path" value="plugins/browser/app/frontend/browserToolCard.tsx" />)

    expect(screen.getByText("Path")).toBeInTheDocument()
    expect(screen.getByText("plugins/browser/app/frontend/browserToolCard.tsx")).toBeInTheDocument()
    expect(document.querySelector("dt")).toBeNull()
    expect(document.querySelector("dd")).toBeNull()
  })
})

function renderReference(reference: ComponentProps<typeof EntityReference>) {
  return render(
    <MemoryRouter>
      <EntityReference {...reference} />
    </MemoryRouter>
  )
}

describe("EntityReference", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it.each([
    [{ kind: "job", id: 42 }, "JOB-42", "/jobs/42"],
    [{ kind: "epic", id: 7 }, "EPIC-7", "/epics/7"],
    [{ kind: "design_doc", id: 9 }, "DOC-9", "/design_docs/9"],
    [{ kind: "chat", id: 5 }, "CHAT-5", "/chats/5"],
    [{ kind: "workflow", id: 3, jobId: 42 }, "WF-3", "/jobs/42?tab=workflows#workflow-3"],
    [{ kind: "run", id: 10, jobId: 42, workflowId: 3 }, "RUN-10", "/jobs/42?tab=workflows#workflow-3"],
    [{ kind: "pull_request", id: 88, prUrl: "https://github.com/acme/widgets/pull/88" }, "PR #88", "https://github.com/acme/widgets/pull/88"],
    [{ kind: "repository", id: 6, repositorySlug: "acme/widgets" }, "acme/widgets", "/repositories/6"]
  ] as Array<[ComponentProps<typeof EntityReference>, string, string]>)("links %s references", (reference, label, href) => {
    renderReference(reference)

    expect(screen.getByRole("link", { name: label })).toHaveAttribute("href", href)
  })

  it.each([
    [{ kind: "artifact", id: "rails_schema_erd" }, "rails_schema_erd"],
    [{ kind: "proposal", slug: "ship-the-widget" }, "ship-the-widget"]
  ] as Array<[ComponentProps<typeof EntityReference>, string]>)("renders %s without requiring a route", (reference, label) => {
    renderReference(reference)

    expect(screen.getByText(label)).toBeInTheDocument()
  })

  it("keeps slug-bearing links copyable without nesting a button inside the link", () => {
    renderReference({ kind: "job", id: 42 })

    const link = screen.getByRole("link", { name: "JOB-42" })
    const copyButton = screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })
    expect(link).toHaveAttribute("href", "/jobs/42")
    expect(link.contains(copyButton)).toBe(false)

    fireEvent.click(copyButton)
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("JOB-42")
  })

  it("falls back to copyable slug text when no route can be derived", () => {
    renderReference({ kind: "repository", slug: "owner/private-repo" })

    fireEvent.click(screen.getByRole("button", { name: "Copy owner/private-repo to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("owner/private-repo")
  })

  it("exposes pure label and href helpers for table-oriented cards", () => {
    expect(entityReferenceLabel({ kind: "workflow", id: 14 })).toBe("WF-14")
    expect(entityReferenceHref({ kind: "workflow", id: 14, jobId: 8 })).toBe("/jobs/8?tab=workflows#workflow-14")
    expect(entityReferenceHref({ kind: "workflow", id: 14 })).toBeNull()
  })
})
