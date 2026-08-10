import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { Markdown, PlainText } from "./Markdown"

describe("Markdown", () => {
  it("renders common chat markdown as React elements", () => {
    render(<Markdown text={"# Notes\n\nDiscuss **aqueducts**, `roads`, and [plans](/plans).\n\n- Survey\n- Build"} />)

    expect(screen.getByRole("heading", { name: "Notes" })).toBeInTheDocument()
    expect(screen.getByText("aqueducts").tagName).toBe("STRONG")
    expect(screen.getByText("roads").tagName).toBe("CODE")
    expect(screen.getByRole("link", { name: "plans" })).toHaveAttribute("href", "/plans")
    expect(screen.getByText("Survey")).toBeInTheDocument()
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
        <Markdown text={"1. **Already in flight**\n   - JOB-2410 timing spans\n   - State: queued\n\n2. **Throughput/review funnel Epic**\n   - EPIC-211 throughput metrics\n   - State: in_progress\n\n3. **Agent Insights infrastructure**\n   - The feature exists\n   - They can use `read_run_worker_health(run_id:)`."} />
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

    expect(screen.getByRole("link", { name: "JOB-100" })).toHaveAttribute("href", "/jobs/100")
    expect(screen.getByRole("link", { name: "EPIC-5" })).toHaveAttribute("href", "/epics/5")
  })

  it("links job and epic slugs inside inline code spans", () => {
    const { container } = render(
      <MemoryRouter>
        <Markdown text="See `JOB-100` and `EPIC-5`" />
      </MemoryRouter>
    )

    const jobLink = screen.getByRole("link", { name: "JOB-100" })
    const epicLink = screen.getByRole("link", { name: "EPIC-5" })

    expect(jobLink).toHaveAttribute("href", "/jobs/100")
    expect(epicLink).toHaveAttribute("href", "/epics/5")
    expect(container.querySelector("code a[href='/jobs/100']")).toBe(jobLink)
    expect(container.querySelector("code a[href='/epics/5']")).toBe(epicLink)
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

  it("renders plain text without applying markdown semantics", () => {
    const text = "1. keep this literal\n**not bold** and `not code`\n- not a list item"
    const { container } = render(<PlainText text={text} />)

    expect(container.firstElementChild?.textContent).toBe(text)
    expect(container.querySelector("ol")).toBeNull()
    expect(container.querySelector("ul")).toBeNull()
    expect(container.querySelector("strong")).toBeNull()
    expect(container.querySelector("code")).toBeNull()
  })
})
