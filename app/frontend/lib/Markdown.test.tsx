import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { allocateMarkdownTableColumns, Markdown, PlainText, renderLightMarkdown } from "./Markdown"
import { setSlugReferenceRegistryForTests, type SlugReferenceRegistryEntry } from "./slugReferenceRegistry"

function registryEntry(overrides: Partial<SlugReferenceRegistryEntry> & Pick<SlugReferenceRegistryEntry, "prefix" | "type">): SlugReferenceRegistryEntry {
  return {
    displayLabel: overrides.prefix,
    copyable: true,
    linkable: true,
    previewAvailable: true,
    linkifiesGeneratedText: true,
    hrefTemplate: null,
    mobileInteractionHints: {},
    pluginPreviewComponent: null,
    ...overrides,
    prefix: overrides.prefix,
    type: overrides.type
  }
}

function domRect(overrides: Partial<DOMRect> = {}): DOMRect {
  return {
    bottom: 0,
    height: 0,
    left: 0,
    right: overrides.width ?? 0,
    top: 0,
    width: 0,
    x: 0,
    y: 0,
    toJSON: () => ({}),
    ...overrides
  } as DOMRect
}

beforeEach(() => {
  setSlugReferenceRegistryForTests([
    registryEntry({ prefix: "JOB", type: "job", hrefTemplate: "/jobs/JOB-:id" }),
    registryEntry({ prefix: "EPIC", type: "epic", hrefTemplate: "/epics/EPIC-:id" })
  ])
})

afterEach(() => {
  setSlugReferenceRegistryForTests(null)
})

describe("Markdown", () => {
  it("renders common chat markdown as React elements", () => {
    render(<Markdown text={"# Notes\n\nDiscuss **aqueducts**, `roads`, and [plans](/plans).\n\n- Survey\n- Build"} />)

    expect(screen.getByRole("heading", { name: "Notes" })).toBeInTheDocument()
    expect(screen.getByText("aqueducts").tagName).toBe("STRONG")
    expect(screen.getByText("roads").tagName).toBe("CODE")
    expect(screen.getByRole("link", { name: "plans" })).toHaveAttribute("href", "/plans")
    expect(screen.getByText("Survey")).toBeInTheDocument()
  })

  it("renders GitHub-ish basics used by Design Docs formatting controls", () => {
    const markdown = [
      "#### Scope",
      "",
      "> Quote **important** context.",
      "",
      "| Feature | Status |",
      "| --- | --- |",
      "| `code` | ~~removed~~ |",
      "",
      "1. First",
      "   - Nested",
      "2. Second",
      "",
      "---",
      "",
      "Plain *italic*, **bold**, `inline`, [link](https://example.test), and ~~strike~~.",
      "",
      "```ts",
      "const enabled = true",
      "```"
    ].join("\n")
    const { container } = render(<Markdown text={markdown} />)

    expect(screen.getByRole("heading", { level: 4, name: "Scope" })).toBeInTheDocument()
    expect(container.querySelector("blockquote strong")).toHaveTextContent("important")
    expect(container.querySelector("table th")).toHaveTextContent("Feature")
    expect(container.querySelector("table code")).toHaveTextContent("code")
    expect(container.querySelector("table del")).toHaveTextContent("removed")
    expect(container.querySelector("ol > li > ul")).toHaveTextContent("Nested")
    expect(container.querySelector("hr")).toBeInTheDocument()
    expect(screen.getByText("italic").tagName).toBe("EM")
    expect(screen.getByText("bold").tagName).toBe("STRONG")
    expect(screen.getByText("inline").tagName).toBe("CODE")
    expect(screen.getByRole("link", { name: "link" })).toHaveAttribute("href", "https://example.test")
    expect(screen.getByText("strike").tagName).toBe("DEL")
    expect(container.querySelector("pre code")).toHaveTextContent("const enabled = true")
  })

  it("renders markdown tables with the chat prose table wrapper", () => {
    const markdown = [
      "| Surface | Notes |",
      "| --- | --- |",
      "| Dashboard Jobs | Long narrative content that should not squeeze the short label column into letter-by-letter wrapping. |",
      "| Inspector | ALongUnbrokenTokenThatStillNeedsToStayInsideTheChatLayoutWithoutBreakingTheMessageShell |",
    ].join("\n")
    const { container } = render(<Markdown text={markdown} />)

    const wrapper = container.querySelector(".chat-prose-table-wrap")
    const table = wrapper?.querySelector("table")

    expect(wrapper).toBeInTheDocument()
    expect(wrapper).toHaveClass("chat-prose-table-wrap")
    expect(wrapper).not.toHaveClass("overflow-x-auto")
    expect(table).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Surface" })).toBeInTheDocument()
    expect(screen.getByRole("cell", { name: "Dashboard Jobs" })).toBeInTheDocument()
    expect(screen.getByText(/Long narrative content/).closest("td")).toBeInTheDocument()
    expect(screen.getByText(/ALongUnbrokenToken/).closest("td")).toBeInTheDocument()
  })

  it("balances tiny label and prose columns for ordinary three-column status tables", () => {
    const markdown = [
      "| # | Section | Status |",
      "| --- | --- | --- |",
      "| 1 | Dashboard | The run summary wraps as ordinary prose and remains readable on mobile. |",
      "| 2 | Review | Final status details stay in the last column instead of being pushed off screen. |"
    ].join("\n")
    const { container } = render(<Markdown text={markdown} />)

    const table = container.querySelector("table")
    const columns = Array.from(container.querySelectorAll("col"))

    expect(table).toHaveClass("chat-prose-table--balanced")
    expect(columns.map((column) => column.getAttribute("data-chat-table-column"))).toEqual(["compact", "label", "prose"])
    expect(columns.map((column) => column.getAttribute("style"))).toEqual([
      "--chat-table-column-width: 11.3%;",
      "--chat-table-column-width: 28.8%;",
      "--chat-table-column-width: 60%;"
    ])
  })

  it("gives two-column label and prose tables balanced width hints", () => {
    const markdown = [
      "| Field | Details |",
      "| --- | --- |",
      "| Trigger label | A normal sentence of breakable prose should receive most of the table width. |",
      "| Branch | Short labels should not force the detail column into a narrow strip. |"
    ].join("\n")
    const { container } = render(<Markdown text={markdown} />)

    const table = container.querySelector("table")
    const columns = Array.from(container.querySelectorAll("col"))

    expect(table).toHaveClass("chat-prose-table--balanced")
    expect(columns.map((column) => column.getAttribute("data-chat-table-column"))).toEqual(["label", "prose"])
    expect(columns.map((column) => column.getAttribute("style"))).toEqual(["--chat-table-column-width: 32.4%;", "--chat-table-column-width: 67.6%;"])
  })

  it("allocates measured table width to prose columns instead of letting short labels dominate", () => {
    const layout = allocateMarkdownTableColumns([
      { kind: "label", min: 68, preferred: 92 },
      { kind: "prose", min: 128, preferred: 620 }
    ], 360)

    expect(layout.wide).toBe(false)
    expect(layout.widths).toEqual([78, 282])
  })

  it("preserves horizontal scrolling only when measured minimum widths cannot fit", () => {
    const layout = allocateMarkdownTableColumns([
      { kind: "label", min: 160, preferred: 180 },
      { kind: "prose", min: 260, preferred: 640 }
    ], 360)

    expect(layout).toEqual({ wide: true, widths: [160, 260] })
  })

  it("measures rendered markdown table columns and applies pixel widths through colgroup", async () => {
    const originalGetBoundingClientRect = HTMLElement.prototype.getBoundingClientRect

    HTMLElement.prototype.getBoundingClientRect = function getBoundingClientRect() {
      if (this.classList.contains("chat-prose-table-wrap")) return domRect({ width: 360 })
      if (this.tagName === "TH" || this.tagName === "TD") {
        const text = this.textContent ?? ""
        const measuringMinContent = this.style.width === "min-content"
        const width = text.includes("Recommendation") || text.includes("Use the browser_use") ? (measuringMinContent ? 128 : 620) : measuringMinContent ? 72 : 92
        return domRect({ width })
      }
      return originalGetBoundingClientRect.call(this)
    }

    try {
      const markdown = [
        "| Plugin | Recommendation |",
        "| --- | --- |",
        "| `browser_use` | Use the browser_use plugin when the task needs browser automation across an external site. |"
      ].join("\n")
      const { container } = render(<Markdown text={markdown} />)

      await waitFor(() => expect(container.querySelector("table")).toHaveClass("chat-prose-table--measured"))
      const columns = Array.from(container.querySelectorAll("col"))

      expect(columns.map((column) => column.getAttribute("data-chat-table-column"))).toEqual(["label", "prose"])
      expect(columns.map((column) => column.getAttribute("style"))).toEqual(["--chat-table-column-width: 78px;", "--chat-table-column-width: 282px;"])
      expect(container.querySelector("table")).not.toHaveClass("chat-prose-table--wide")
    } finally {
      HTMLElement.prototype.getBoundingClientRect = originalGetBoundingClientRect
    }
  })

  it("marks tables with unbroken tokens as wide while keeping them wrapped for containment", () => {
    const markdown = ["| Label | Value |", "| --- | --- |", "| Artifact | https://example.test/downloads/ALongUnbrokenTokenThatCannotWrapNaturally |"].join(
      "\n"
    )
    const { container } = render(<Markdown text={markdown} />)

    const wrapper = container.querySelector(".chat-prose-table-wrap")
    const table = container.querySelector("table")

    expect(wrapper).toBeInTheDocument()
    expect(table).toHaveClass("chat-prose-table--wide")
    expect(table).not.toHaveClass("chat-prose-table--balanced")
    expect(container.querySelector("col[data-chat-table-column='prose']")).toBeInTheDocument()
    expect(screen.getByText("https://example.test/downloads/ALongUnbrokenTokenThatCannotWrapNaturally")).toBeInTheDocument()
  })

  it("renders strong emphasis that spans a soft-broken source line", () => {
    const { container } = render(
      <Markdown text={"## 4. Open-core boundary\n\n**Decision: OSS ships mechanism, including good isolation. Commercial ships\ntenancy.**\n\nIsolation is commodity."} />
    )

    const strong = container.querySelector("p strong")
    expect(screen.getByRole("heading", { level: 2, name: "4. Open-core boundary" })).toBeInTheDocument()
    expect(strong).toHaveTextContent("Decision: OSS ships mechanism, including good isolation. Commercial ships tenancy.")
    expect(container.textContent).not.toContain("**Decision")
    expect(container.textContent).not.toContain("tenancy.**")
  })

  it("keeps ordinary emphasis working and unmatched strong markers inert", () => {
    const { container } = render(<Markdown text={"Plain **bold** and *italic*. This **never closes."} />)

    expect(screen.getByText("bold").tagName).toBe("STRONG")
    expect(screen.getByText("italic").tagName).toBe("EM")
    expect(container).toHaveTextContent("This **never closes.")
    expect(container.querySelectorAll("strong")).toHaveLength(1)
  })

  it("keeps raw HTML as inert text", () => {
    const { container } = render(<Markdown text={"Hello <script>alert('x')</script> **friend**"} />)

    expect(screen.getByText(/<script>alert\('x'\)<\/script>/)).toBeInTheDocument()
    expect(screen.getByText("friend").tagName).toBe("STRONG")
    expect(container.querySelector("script")).toBeNull()
  })

  it("keeps ordered lists consecutive when items are separated by blank lines", () => {
    const { container } = render(<Markdown text={"1. First\n\n1. Second\n\n1. Third"} />)

    const lists = container.querySelectorAll("ol")
    const items = Array.from(lists[0].querySelectorAll("li"))
    expect(lists).toHaveLength(1)
    expect(items).toHaveLength(3)
    expect(items.map((item) => item.getAttribute("value"))).toEqual(["1", "1", "1"])
    expect(screen.getByText("First")).toBeInTheDocument()
    expect(screen.getByText("Second")).toBeInTheDocument()
    expect(screen.getByText("Third")).toBeInTheDocument()
  })

  it("preserves raw ordered list numbers", () => {
    const { container } = render(<Markdown text={"2. Second\n5. Fifth\n7. Seventh"} />)

    const list = container.querySelector("ol")
    const items = Array.from(container.querySelectorAll("li"))
    expect(list).toHaveAttribute("start", "2")
    expect(items.map((item) => item.getAttribute("value"))).toEqual(["2", "5", "7"])
  })

  it("renders indented lists as children of their parent item", () => {
    const { container } = render(
      <Markdown text={"1. First track\n   - Child A\n   - Child B\n2. Second track\n   - Child C"} />
    )

    const topList = container.querySelector("ol")
    expect(topList?.children).toHaveLength(2)
    expect(topList?.children[0]).toHaveTextContent("First trackChild AChild B")
    expect(topList?.children[1]).toHaveTextContent("Second trackChild C")
    expect(topList?.querySelectorAll(":scope > li > ul")).toHaveLength(2)
    expect(Array.from(topList?.querySelectorAll(":scope > li") ?? []).map((item) => item.getAttribute("value"))).toEqual(["1", "2"])
  })

  it("keeps reported markdown section numbers and nested bullet indentation", () => {
    const { container } = render(
      <MemoryRouter>
        <Markdown text={"1. **Already in flight**\n   - JOB-110 timing spans\n   - State: queued\n\n2. **Throughput/review funnel Epic**\n   - the Tier 1 tool-card work throughput metrics\n   - State: in_progress\n\n3. **Agent Insights infrastructure**\n   - The feature exists\n   - They can use `read_run_worker_health(run_id:)`."} />
      </MemoryRouter>
    )

    const topList = container.querySelector("ol")
    const topItems = Array.from(topList?.querySelectorAll(":scope > li") ?? [])
    expect(topItems.map((item) => item.getAttribute("value"))).toEqual(["1", "2", "3"])
    expect(topItems.map((item) => item.querySelector(":scope > strong")?.textContent)).toEqual([
      "Already in flight",
      "Throughput/review funnel Epic",
      "Agent Insights infrastructure",
    ])
    expect(topList?.querySelectorAll(":scope > li > ul")).toHaveLength(3)
    expect(screen.getByText("read_run_worker_health(run_id:)").tagName).toBe("CODE")
  })

  it("links job and epic slugs in plain text", () => {
    render(
      <MemoryRouter>
        <Markdown text="See JOB-100 and EPIC-5" />
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: "JOB-100" })).toHaveAttribute("href", "/jobs/JOB-100")
    expect(screen.getByRole("link", { name: "EPIC-5" })).toHaveAttribute("href", "/epics/EPIC-5")
  })

  it("links job and epic slugs inside inline code spans", () => {
    const { container } = render(
      <MemoryRouter>
        <Markdown text="See `JOB-100` and `EPIC-5`" />
      </MemoryRouter>
    )

    const jobLink = screen.getByRole("link", { name: "JOB-100" })
    const epicLink = screen.getByRole("link", { name: "EPIC-5" })

    expect(jobLink).toHaveAttribute("href", "/jobs/JOB-100")
    expect(epicLink).toHaveAttribute("href", "/epics/EPIC-5")
    expect(container.querySelector("code a[href='/jobs/JOB-100']")).toBe(jobLink)
    expect(container.querySelector("code a[href='/epics/EPIC-5']")).toBe(epicLink)
  })

  it("does not linkify slugs inside markdown links", () => {
    render(
      <MemoryRouter>
        <Markdown text="[JOB-100](/custom)" />
      </MemoryRouter>
    )

    const links = screen.getAllByRole("link")
    expect(links).toHaveLength(1)
    expect(links[0]).toHaveAttribute("href", "/custom")
  })

  it("links complete plain HTTP and HTTPS URLs when requested", () => {
    render(<Markdown text="Open https://example.test/chats/517 and http://localhost:3000/admin." linkifyUrls />)

    expect(screen.getByRole("link", { name: "https://example.test/chats/517" })).toHaveAttribute("href", "https://example.test/chats/517")
    expect(screen.getByRole("link", { name: "http://localhost:3000/admin" })).toHaveAttribute("href", "http://localhost:3000/admin")
    expect(document.querySelector("p")).toHaveTextContent("Open https://example.test/chats/517 and http://localhost:3000/admin.")
  })

  it("does not double-link URLs that are already markdown links", () => {
    render(<Markdown text="Open [the chat](https://example.test/chats/517)." linkifyUrls />)

    const links = screen.getAllByRole("link")
    expect(links).toHaveLength(1)
    expect(links[0]).toHaveAccessibleName("the chat")
    expect(links[0]).toHaveAttribute("href", "https://example.test/chats/517")
  })

  it("does not auto-link URL text inside a markdown link label", () => {
    render(<Markdown text="[https://example.test/chats/517](https://example.test/chats/517)" linkifyUrls />)

    const links = screen.getAllByRole("link")
    expect(links).toHaveLength(1)
    expect(links[0]).toHaveAccessibleName("https://example.test/chats/517")
    expect(links[0]).toHaveAttribute("href", "https://example.test/chats/517")
    expect(links[0].querySelector("a")).toBeNull()
  })

  it("does not link incomplete or unsafe plain URLs", () => {
    render(<Markdown text="Skip https:// and javascript:alert(1)." linkifyUrls />)

    expect(screen.queryByRole("link")).toBeNull()
    expect(screen.getByText("Skip https:// and javascript:alert(1).")).toBeInTheDocument()
  })

  it("keeps plain URLs inside inline code spans as code text", () => {
    const { container } = render(<Markdown text="Use `https://example.test/token` literally." linkifyUrls />)

    expect(screen.queryByRole("link")).toBeNull()
    expect(screen.getByText("https://example.test/token").tagName).toBe("CODE")
    expect(container.querySelector("code")).toHaveTextContent("https://example.test/token")
  })

  it("decodes HTML entities in prose text", () => {
    render(<Markdown text={"A job throttled for &lt;30 min and &gt;1 hr uses &amp;amp; and &quot;quotes&quot; and &apos;apos&apos;"} />)

    expect(screen.getByText(/A job throttled for <30 min and >1 hr uses &amp; and "quotes" and 'apos'/)).toBeInTheDocument()
  })

  it("decodes numeric HTML entities in prose text", () => {
    render(<Markdown text={"arrow &#60; and &#x3E; and &#169;"} />)

    expect(screen.getByText(/arrow < and > and ©/)).toBeInTheDocument()
  })

  it("decodes HTML entities inside list items", () => {
    render(<Markdown text={"- shows &lt;30 min pill\n- shows &gt;30 min pill"} />)

    expect(screen.getByText(/shows <30 min pill/)).toBeInTheDocument()
    expect(screen.getByText(/shows >30 min pill/)).toBeInTheDocument()
  })

  it("renders fenced code blocks as scrollable pre > code elements", () => {
    const { container } = render(<Markdown text={"```\nconst x = 1\n```"} />)
    const pre = container.querySelector("pre")
    expect(pre).toBeInTheDocument()
    expect(pre?.querySelector("code")?.textContent).toBe("const x = 1")
  })

  it("highlights fenced code blocks using the language hint from the info string", async () => {
    render(<Markdown text={"```ruby\nclass User\nend\n```"} />)

    const keyword = await screen.findByText("class")
    expect(keyword.tagName).toBe("SPAN")
    expect(keyword.style.color).toBe("var(--shiki-token-keyword)")
  })

  it("renders inline TeX math as selectable KaTeX HTML and MathML", () => {
    const { container } = render(<Markdown text={"Smooth interpolation uses $t^2(3 - 2t)$ for easing."} />)

    const math = container.querySelector(".syrus-inline-math")
    expect(math).toBeInTheDocument()
    expect(math?.querySelector(".katex-html")).toBeInTheDocument()
    expect(math?.querySelector(".katex-mathml math")).not.toBeNull()
    expect(math).toHaveTextContent("t")
    expect(screen.getByText(/Smooth interpolation uses/)).toBeInTheDocument()
  })

  it("renders parenthesized inline TeX math delimiters", () => {
    const { container } = render(<Markdown text={"The derivative is \\(2t\\)."} />)

    expect(container.querySelector(".syrus-inline-math .katex-html")).toBeInTheDocument()
    expect(container.querySelector(".syrus-inline-math .katex-mathml math")).not.toBeNull()
  })

  it("renders numeric inline TeX formulas without treating prices as formulas", () => {
    const { container } = render(<Markdown text={"Arithmetic $2+2=4$ costs $5 today."} />)

    expect(container.querySelector(".syrus-inline-math .katex-html")).toBeInTheDocument()
    expect(screen.getByText(/costs \$5 today/)).toBeInTheDocument()
  })

  it("renders inline TeX math in list items and table cells", () => {
    const { container } = render(
      <Markdown text={"- Blend with $x_i^2$\n\n| Name | Formula |\n| --- | --- |\n| smootherstep | $t^3(10 - 15t + 6t^2)$ |"} />
    )

    expect(container.querySelector("li .syrus-inline-math .katex-html")).toBeInTheDocument()
    expect(container.querySelector("td .syrus-inline-math .katex-html")).toBeInTheDocument()
  })

  it("preserves dollar-delimited math inside inline code spans as code text", () => {
    const { container } = render(<Markdown text={"Use `$t^2$` literally in docs."} />)

    expect(screen.getByText("$t^2$").tagName).toBe("CODE")
    expect(container.querySelector(".syrus-inline-math")).toBeNull()
  })

  it("does not render inline math inside markdown link labels", () => {
    const { container } = render(<Markdown text={"[$t^2$ details](/docs)"} />)

    expect(screen.getByRole("link", { name: "$t^2$ details" })).toHaveAttribute("href", "/docs")
    expect(container.querySelector(".syrus-inline-math")).toBeNull()
  })

  it("preserves dollar-delimited math inside fenced code blocks as code text", () => {
    const { container } = render(<Markdown text={"```\nconst label = '$t^2$'\n```"} />)

    expect(container.querySelector("pre code")).toHaveTextContent("const label = '$t^2$'")
    expect(container.querySelector(".syrus-inline-math")).toBeNull()
  })

  it("does not treat ordinary currency as inline math", () => {
    const { container } = render(<Markdown text={"The cost is $5 today and $10 tomorrow."} />)

    expect(screen.getByText("The cost is $5 today and $10 tomorrow.")).toBeInTheDocument()
    expect(container.querySelector(".syrus-inline-math")).toBeNull()
  })

  it("does not let rejected currency spans consume later inline math", () => {
    const { container } = render(<Markdown text={"Cost is $5 today and formula $x^2$ renders."} />)

    expect(screen.getByText(/Cost is \$5 today and formula/)).toBeInTheDocument()
    expect(container.querySelector(".syrus-inline-math .katex-html")).toBeInTheDocument()
    expect(container.querySelector(".syrus-inline-math")).toHaveTextContent("x")
  })

  it("leaves unmatched dollar delimiters as prose", () => {
    const { container } = render(<Markdown text={"This formula starts $t^2 but never closes."} />)

    expect(screen.getByText("This formula starts $t^2 but never closes.")).toBeInTheDocument()
    expect(container.querySelector(".syrus-inline-math")).toBeNull()
  })

  it("keeps slug autolinks working next to inline math", () => {
    const { container } = render(
      <MemoryRouter>
        <Markdown text={"JOB-100 uses $t^2(3 - 2t)$ before EPIC-5."} />
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: "JOB-100" })).toHaveAttribute("href", "/jobs/JOB-100")
    expect(screen.getByRole("link", { name: "EPIC-5" })).toHaveAttribute("href", "/epics/EPIC-5")
    expect(container.querySelector(".syrus-inline-math .katex-html")).toBeInTheDocument()
  })

  it("truncates pathological lines without disabling markdown rendering", () => {
    const { container } = render(<Markdown text={`# Notes\n\n${"a".repeat(45_000)}\n\n- Review`} />)

    expect(screen.getByRole("heading", { name: "Notes" })).toBeInTheDocument()
    expect(screen.getByText("Review")).toBeInTheDocument()
    expect(screen.getByText(/One or more lines were truncated/)).toBeInTheDocument()
    expect(container.querySelector("p")?.textContent?.length).toBeLessThanOrEqual(2_100)
  })

  it("renders plain text without applying markdown semantics", () => {
    const text = "1. keep this literal\n**not bold** and `not code`\n- not a list item"
    const { container } = render(<PlainText text={text} />)

    expect(container.firstElementChild?.textContent).toBe(text)
    expect(container.querySelector("ol")).toBeNull()
    expect(container.querySelector("ul")).toBeNull()
    expect(container.querySelector("strong")).toBeNull()
    expect(container.querySelector("code")).toBeNull()
  })

  it("links plain URLs in plain text when requested without applying markdown semantics", () => {
    const text = "Visit https://example.test/docs\n**not bold**"
    const { container } = render(<PlainText text={text} linkifyUrls />)

    expect(screen.getByRole("link", { name: "https://example.test/docs" })).toHaveAttribute("href", "https://example.test/docs")
    expect(container.querySelector("strong")).toBeNull()
    expect(container.firstElementChild?.textContent).toBe("Visit https://example.test/docs\n**not bold**")
  })
})

describe("renderLightMarkdown", () => {
  it("renders a heading as bold text with no literal # marker and no line break", () => {
    const { container } = render(<div>{renderLightMarkdown("# Title\n\nBody text.")}</div>)

    expect(container.querySelector("strong")).toHaveTextContent("Title")
    expect(container.querySelector("h1")).toBeNull()
    expect(container.querySelector("h2")).toBeNull()
    expect(container.textContent).toBe("Title Body text.")
    expect(container.textContent).not.toContain("#")
    expect(container.innerHTML).not.toContain("<br")
  })

  it("flattens multi-paragraph input into one space-joined string with no line breaks", () => {
    const { container } = render(<div>{renderLightMarkdown("Paragraph one.\n\nParagraph two.\n\nParagraph three.")}</div>)

    expect(container.textContent).toBe("Paragraph one. Paragraph two. Paragraph three.")
    expect(container.textContent).not.toContain("\n")
  })

  it("keeps light inline emphasis: bold, italic, and inline code", () => {
    const { container } = render(<div>{renderLightMarkdown("Some **bold**, *italic*, and `code` text.")}</div>)

    expect(container.querySelector("strong")).toHaveTextContent("bold")
    expect(container.querySelector("em")).toHaveTextContent("italic")
    expect(container.querySelector("code")).toHaveTextContent("code")
  })

  it("strips list markers and blockquote markers", () => {
    const { container } = render(<div>{renderLightMarkdown("- First item\n- Second item\n> A quoted line")}</div>)

    expect(container.textContent).toBe("First item Second item A quoted line")
  })

  it("linkifies slugs by default, matching renderInline's default", () => {
    render(
      <MemoryRouter>
        <div>{renderLightMarkdown("See JOB-100 for details.")}</div>
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: "JOB-100" })).toHaveAttribute("href", "/jobs/JOB-100")
  })

  it("skips slug linkification when linkifySlugs is false", () => {
    render(<div>{renderLightMarkdown("See JOB-100 for details.", { linkifySlugs: false })}</div>)

    expect(screen.queryByRole("link")).toBeNull()
    expect(screen.getByText(/See JOB-100 for details\./)).toBeInTheDocument()
  })
})
