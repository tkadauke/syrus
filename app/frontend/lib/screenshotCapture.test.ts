import { describe, expect, it, vi } from "vitest"
import {
  captureFullPage,
  MAX_FULL_PAGE_CAPTURE_ELEMENTS,
  SCROLL_ATTRIBUTE,
  UnsafeFullPageCaptureError,
  hollowOffscreenElements,
  planHollowing,
  restoreScrollPositions,
  tagScrollPositions
} from "./screenshotCapture"

// jsdom has no layout, so rects are stubbed; the pixel-level guarantee lives
// in e2e/screenshot-capture-parity.spec.ts.
const bounds = { top: -100, bottom: 900, left: -100, right: 1100 }

function rect(top: number, height: number, left = 0, width = 600): DOMRect {
  return { top, bottom: top + height, left, right: left + width, width, height, x: left, y: top, toJSON: () => ({}) } as DOMRect
}

function buildDiff(doc: Document, rowTops: number[]) {
  doc.body.innerHTML = `<table><tbody>${rowTops
    .map((_, i) => `<tr data-capture-hollow=""><td>${i}</td><td><span class="tok">const</span> <span class="tok">v${i}</span></td></tr>`)
    .join("")}</tbody></table><div data-capture-hollow="" id="block"><p>block content</p></div>`
}

function stubLayout(doc: Document, rowTops: number[], blockTop: number) {
  doc.querySelectorAll("tr").forEach((row, i) => {
    row.getBoundingClientRect = () => rect(rowTops[i], 20)
    Array.from(row.children).forEach((cell, c) => {
      ;(cell as HTMLElement).getBoundingClientRect = () => rect(rowTops[i], 20, c * 48, c === 0 ? 48 : 552.5)
    })
  })
  ;(doc.getElementById("block") as HTMLElement).getBoundingClientRect = () => rect(blockTop, 120)
}

function documents(rowTops: number[], blockTop: number) {
  const original = document.implementation.createHTMLDocument("original")
  const clone = document.implementation.createHTMLDocument("clone")
  buildDiff(original, rowTops)
  buildDiff(clone, rowTops)
  stubLayout(original, rowTops, blockTop)
  return { original, clone }
}

describe("hollowOffscreenElements", () => {
  it("hollows off-screen table rows cell by cell, freezing each cell at its rendered size", () => {
    const tops = [-500, 100, 2000]
    const { original, clone } = documents(tops, 300)

    expect(hollowOffscreenElements(original, clone, bounds)).toBe(2)

    const [above, visible, below] = Array.from(clone.querySelectorAll("tr"))
    for (const row of [above, below]) {
      expect(row.children).toHaveLength(2)
      const [gutter, code] = Array.from(row.children) as HTMLElement[]
      expect(gutter.childNodes).toHaveLength(0)
      expect(code.childNodes).toHaveLength(0)
      expect(gutter.style.width).toBe("48px")
      expect(code.style.width).toBe("552.5px")
      expect(code.style.height).toBe("20px")
      expect(code.style.getPropertyValue("box-sizing")).toBe("border-box")
    }
    expect(visible.querySelectorAll(".tok")).toHaveLength(2)
    expect((visible.children[1] as HTMLElement).style.width).toBe("")
  })

  it("freezes a non-row element's own box and leaves elements near the viewport alone", () => {
    const { original, clone } = documents([100], 5000)

    expect(hollowOffscreenElements(original, clone, bounds)).toBe(1)

    const block = clone.getElementById("block") as HTMLElement
    expect(block.childNodes).toHaveLength(0)
    expect(block.style.height).toBe("120px")
    expect(clone.querySelector("tr .tok")).not.toBeNull()
  })

  it("keeps rows inside the margin around the viewport", () => {
    const { original, clone } = documents([-90, 880], 300)

    expect(hollowOffscreenElements(original, clone, bounds)).toBe(0)
    expect(clone.querySelectorAll(".tok")).toHaveLength(4)
  })

  it("does nothing when the clone no longer mirrors the original", () => {
    const { original, clone } = documents([-500, 2000], 5000)
    clone.querySelector("tr")?.remove()

    expect(hollowOffscreenElements(original, clone, bounds)).toBe(0)
    expect(clone.querySelectorAll(".tok")).toHaveLength(2)
  })

  it("plans which contents html2canvas skips while cloning", () => {
    const { original } = documents([-500, 100], 5000)
    const plan = planHollowing(original, bounds)

    const [above, visible] = Array.from(original.querySelectorAll("tr"))
    const block = original.getElementById("block") as HTMLElement
    // The cells of the hollowed row and the block are kept but emptied...
    expect(Array.from(plan.emptied)).toEqual([...Array.from(above.children), block])
    // ...so their descendants are never cloned.
    expect(plan.emptied.has(visible.children[1])).toBe(false)
    expect(plan.emptied.has(above)).toBe(false)
    expect(Array.from(plan.rows.keys())).toEqual([0, 2])
  })

  it("ignores opted-in elements nested inside another opted-in element", () => {
    const original = document.implementation.createHTMLDocument("original")
    original.body.innerHTML = `<div data-capture-hollow="" id="outer"><div data-capture-hollow="" id="inner"><span>x</span></div></div>`
    ;(original.getElementById("outer") as HTMLElement).getBoundingClientRect = () => rect(5000, 100)
    ;(original.getElementById("inner") as HTMLElement).getBoundingClientRect = () => rect(5000, 50)

    const plan = planHollowing(original, bounds)

    expect(plan.rows.size).toBe(1)
    expect(Array.from(plan.emptied)).toEqual([original.getElementById("outer")])
  })

  it("hollows a whole off-screen file, and only the off-screen rows of a visible one", () => {
    const html = ["far", "near"]
      .map(
        (id) =>
          `<div data-capture-hollow="" id="${id}"><table><tbody>${[0, 1]
            .map((row) => `<tr data-capture-hollow="" id="${id}-${row}"><td><span class="tok">${id}${row}</span></td></tr>`)
            .join("")}</tbody></table></div>`
      )
      .join("")
    const original = document.implementation.createHTMLDocument("original")
    const clone = document.implementation.createHTMLDocument("clone")
    original.body.innerHTML = html
    clone.body.innerHTML = html
    const tops: Record<string, number> = { far: -3000, "far-0": -3000, "far-1": -2980, near: 0, "near-0": 0, "near-1": 2000 }
    original.querySelectorAll<HTMLElement>("[id]").forEach((el) => {
      el.getBoundingClientRect = () => rect(tops[el.id], el.tagName === "DIV" ? 2020 : 20)
      el.querySelectorAll<HTMLElement>("td").forEach((cell) => (cell.getBoundingClientRect = () => rect(tops[el.id], 20)))
    })

    // The far file, and the near file's second row: the far file's rows are
    // never visited, so the indexes in clone and original line up.
    expect(hollowOffscreenElements(original, clone, bounds)).toBe(2)
    expect(Array.from(clone.querySelectorAll(".tok")).map((tok) => tok.textContent)).toEqual(["near0"])
    expect(clone.getElementById("far")?.childNodes).toHaveLength(0)
    expect((clone.getElementById("far") as HTMLElement).style.height).toBe("2020px")
  })
})

describe("scroll restoration", () => {
  it("carries each scrolled element's offsets into the clone, whatever else the clone lacks", () => {
    document.body.innerHTML = `<div id="gone"><span></span></div><div id="scroller"></div><div id="still"></div>`
    const scroller = document.getElementById("scroller") as HTMLElement
    Object.defineProperty(scroller, "scrollTop", { value: 120, configurable: true })
    Object.defineProperty(scroller, "scrollLeft", { value: 30, configurable: true })

    const untag = tagScrollPositions(document)
    // html2canvas copies attributes, and leaves out hollowed contents.
    const clone = document.cloneNode(true) as Document
    clone.querySelector("#gone span")?.remove()
    untag()
    expect(scroller.hasAttribute(SCROLL_ATTRIBUTE)).toBe(false)

    // jsdom has no layout and drops scroll writes, so record them instead.
    const writes: Record<string, [number, number]> = {}
    clone.querySelectorAll("div").forEach((el) => {
      writes[el.id] = [0, 0]
      Object.defineProperty(el, "scrollTop", { get: () => 0, set: (value: number) => (writes[el.id][1] = value), configurable: true })
      Object.defineProperty(el, "scrollLeft", { get: () => 0, set: (value: number) => (writes[el.id][0] = value), configurable: true })
    })
    const windowScroll = vi.fn()
    Object.defineProperty(clone, "defaultView", { value: { scrollTo: windowScroll }, configurable: true })

    restoreScrollPositions(clone, 0, 480)

    expect(writes).toEqual({ gone: [0, 0], scroller: [30, 120], still: [0, 0] })
    expect(windowScroll).toHaveBeenCalledWith(0, 480)
    expect(clone.querySelector(`[${SCROLL_ATTRIBUTE}]`)).toBeNull()
    // Scroll anchoring would otherwise shift offsets once hollowed rows regain height.
    expect(clone.head.textContent).toContain("overflow-anchor: none")
  })
})

describe("full-page resource policy", () => {
  it("rejects a document whose DOM is too complex before invoking html2canvas", () => {
    const html2canvas = vi.fn()
    const elements = document.getElementsByTagName.bind(document)
    vi.spyOn(document, "getElementsByTagName").mockImplementation(((name: string) => {
      if (name === "*") return { length: MAX_FULL_PAGE_CAPTURE_ELEMENTS + 1 } as HTMLCollectionOf<Element>
      return elements(name)
    }) as typeof document.getElementsByTagName)

    expect(() => captureFullPage(html2canvas as never)).toThrow(UnsafeFullPageCaptureError)
    expect(html2canvas).not.toHaveBeenCalled()
  })
})
