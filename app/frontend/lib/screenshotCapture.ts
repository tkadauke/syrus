// Screenshot capture for bug reports, built on html2canvas.
//
// html2canvas does work for every element on the page -- it clones the whole
// document, reads every element's computed style and builds a render tree for
// all of it -- and only crops to the requested area at the end. A viewport
// capture of a long review diff (tens of thousands of token spans) therefore
// takes as long as a full-page one: ~0.1 ms per element.
//
// Hollowing removes that cost for content the viewport cannot show. A component
// opts elements in with `data-capture-hollow` -- a whole file of a diff, and
// its rows for when the file is only partly visible. Every opted-in element
// entirely outside the viewport (plus a margin) keeps its exact box in
// html2canvas's clone, but its contents are never cloned, so html2canvas does
// no work for them. Layout is untouched, so the visible pixels are identical --
// e2e/screenshot-capture-parity.spec.ts holds that to an exact pixel match.
//
// Opt in only elements whose contents never paint outside their own box on
// the axis where they are off-screen: no overflowing, absolutely or fixed
// positioned or transformed descendants, and no sticky ones that could pin
// into view. Table rows hollow cell by cell, so column widths still see every
// cell at its rendered size.

export type Html2Canvas = typeof import("html2canvas-pro").default
export type CaptureMode = "viewport" | "fullPage"
export type CaptureOptions = { hollowOffscreen?: boolean }

export const HOLLOW_ATTRIBUTE = "data-capture-hollow"
export const MAX_FULL_PAGE_SCREENSHOT_PIXELS = 8_000_000
export const MIN_FULL_PAGE_SCREENSHOT_SCALE = 0.25
export const MAX_FULL_PAGE_CAPTURE_ELEMENTS = 50_000

export class UnsafeFullPageCaptureError extends Error {
  constructor() {
    super("The page is too large to capture safely")
    this.name = "UnsafeFullPageCaptureError"
  }
}

let html2canvasPromise: Promise<Html2Canvas> | null = null
// How many elements the latest viewport capture hollowed; read by the debug
// hook so the parity spec can tell a real comparison from a vacuous one.
let lastHollowedCount = 0

export function loadHtml2Canvas() {
  html2canvasPromise ||= import("html2canvas-pro").then((module) => module.default)
  return html2canvasPromise
}

export function captureViewport(html2canvas: Html2Canvas, options: CaptureOptions = {}) {
  const hollowOffscreen = options.hollowOffscreen ?? true
  // Decide what to hollow from the live page before html2canvas starts: its
  // clone pass calls getComputedStyle three times per element, so contents it
  // never clones are the bulk of the saving.
  const plan = hollowOffscreen ? planHollowing(document, viewportBounds()) : null
  lastHollowedCount = plan?.rows.size ?? 0
  const scrollX = window.scrollX
  const scrollY = window.scrollY
  const untag = tagScrollPositions(document)
  return html2canvas(document.body, {
    x: scrollX,
    y: scrollY,
    width: window.innerWidth,
    height: window.innerHeight,
    windowWidth: window.innerWidth,
    windowHeight: window.innerHeight,
    useCORS: true,
    ignoreElements: plan ? (element) => plan.emptied.has(element.parentElement as Element) : undefined,
    onclone: (_clonedDoc, element) => {
      const clonedDoc = element.ownerDocument
      normalizeCloneForCapture(clonedDoc, "viewport")
      // Hollowed boxes must have their size back before scroll positions are
      // restored, or the shorter document clamps them.
      if (plan) applyHollowing(plan, clonedDoc)
      restoreScrollPositions(clonedDoc, scrollX, scrollY)
      untag()
    }
  }).finally(untag)
}

// A full-page capture shows everything, so nothing is hollowed.
export function captureFullPage(html2canvas: Html2Canvas) {
  const width = Math.max(document.body.scrollWidth, document.documentElement.scrollWidth, window.innerWidth)
  const height = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, window.innerHeight)
  const scale = Math.min(1, Math.sqrt(MAX_FULL_PAGE_SCREENSHOT_PIXELS / (width * height)))
  if (scale < MIN_FULL_PAGE_SCREENSHOT_SCALE || document.getElementsByTagName("*").length > MAX_FULL_PAGE_CAPTURE_ELEMENTS) {
    throw new UnsafeFullPageCaptureError()
  }
  const untag = tagScrollPositions(document)

  return html2canvas(document.body, {
    x: 0,
    y: 0,
    width,
    height,
    scrollX: 0,
    scrollY: 0,
    scale,
    windowWidth: window.innerWidth,
    windowHeight: window.innerHeight,
    useCORS: true,
    onclone: (_clonedDoc, element) => {
      normalizeCloneForCapture(element.ownerDocument, "fullPage")
      restoreScrollPositions(element.ownerDocument, 0, 0)
      untag()
    }
  }).finally(untag)
}

export function normalizeCloneForCapture(clonedDoc: Document, captureMode: CaptureMode) {
  clonedDoc.querySelectorAll<HTMLDetailsElement>("details:not([open])").forEach((details) => {
    Array.from(details.children).forEach((child) => {
      if (child.tagName.toLowerCase() === "summary") return
      if (child instanceof HTMLElement) child.style.setProperty("display", "none", "important")
    })
  })

  // Viewport captures need the browser's current sticky placement. Full-page
  // captures render the document from its origin, where sticky elements should
  // participate in normal flow instead of pinning over content farther down.
  if (captureMode === "fullPage") {
    clonedDoc.querySelectorAll<HTMLElement>("*").forEach((clonedEl) => {
      if (getComputedStyle(clonedEl).position === "sticky") clonedEl.style.position = "relative"
    })
  }
}

// Inner scroll containers (the chat message stream, a review diff) must render
// at their current offsets. html2canvas restores them when its clone loads, but
// anything that changes the clone's layout afterwards -- closing <details>,
// hollowing -- can clamp them or let scroll anchoring move them. So every
// scrolled element carries its offsets into the clone on a temporary
// attribute, and they are applied once the clone's layout is final. The
// attribute travels with the element itself, so nothing depends on pairing
// original and cloned elements by position.
export const SCROLL_ATTRIBUTE = "data-capture-scroll"

export function tagScrollPositions(doc: Document) {
  const tagged: HTMLElement[] = []
  doc.querySelectorAll<HTMLElement>("*").forEach((el) => {
    if (el.scrollTop === 0 && el.scrollLeft === 0) return
    el.setAttribute(SCROLL_ATTRIBUTE, `${el.scrollLeft},${el.scrollTop}`)
    tagged.push(el)
  })
  return () => {
    tagged.forEach((el) => el.removeAttribute(SCROLL_ATTRIBUTE))
    tagged.length = 0
  }
}

export function restoreScrollPositions(clonedDoc: Document, windowX: number, windowY: number) {
  const anchoring = clonedDoc.createElement("style")
  anchoring.textContent = "* { overflow-anchor: none !important; }"
  clonedDoc.head.appendChild(anchoring)
  clonedDoc.querySelectorAll<HTMLElement>(`[${SCROLL_ATTRIBUTE}]`).forEach((el) => {
    const [left, top] = (el.getAttribute(SCROLL_ATTRIBUTE) ?? "").split(",").map(Number)
    el.removeAttribute(SCROLL_ATTRIBUTE)
    el.scrollLeft = left || 0
    el.scrollTop = top || 0
  })
  clonedDoc.defaultView?.scrollTo(windowX, windowY)
}

type Bounds = { top: number; bottom: number; left: number; right: number }

// The viewport plus half a screen on every side: generous enough for sticky
// headers and sub-pixel rounding, small enough to keep the saving.
function viewportBounds(): Bounds {
  const marginY = window.innerHeight / 2
  const marginX = window.innerWidth / 2
  return { top: -marginY, bottom: window.innerHeight + marginY, left: -marginX, right: window.innerWidth + marginX }
}

function outside(rect: DOMRect, bounds: Bounds) {
  const above = rect.bottom < bounds.top
  const below = rect.top > bounds.bottom
  const beside = rect.right < bounds.left || rect.left > bounds.right
  return above || below || beside
}

export type HollowPlan = {
  // Hollowed opted-in elements, keyed by their position among the opted-in
  // elements that survive into the clone (see walkCandidates), with each box
  // to freeze: -1 for the element itself, otherwise the index of a table cell.
  rows: Map<number, Array<[number, DOMRect]>>
  // Original elements whose children html2canvas must not clone.
  emptied: Set<Element>
  // How many opted-in elements survive into the clone; a clone that disagrees
  // does not mirror the original and is left alone.
  survivors: number
}

// Opted-in elements may nest -- a whole file, and the rows inside it. Once an
// element is hollowed, the opted-in elements inside it are gone from the
// clone, so both documents are walked the same way: every opted-in element not
// inside a hollowed one gets the next index, and `hollow` decides from that
// index whether it is hollowed.
function walkCandidates(doc: Document, hollow: (element: HTMLElement, index: number) => boolean): number {
  const selector = `[${HOLLOW_ATTRIBUTE}]`
  const gone = new Set<Element>()
  let index = 0
  doc.querySelectorAll<HTMLElement>(selector).forEach((element) => {
    const parent = element.parentElement?.closest(selector)
    if (parent && gone.has(parent)) {
      gone.add(element)
      return
    }
    if (hollow(element, index++)) gone.add(element)
  })
  return index
}

export function planHollowing(originalDoc: Document, bounds: Bounds): HollowPlan {
  const plan: HollowPlan = { rows: new Map(), emptied: new Set(), survivors: 0 }
  plan.survivors = walkCandidates(originalDoc, (original, index) => {
    if (!outside(original.getBoundingClientRect(), bounds)) return false
    // Table rows hollow cell by cell, so column widths still see every cell.
    const targets: Array<[number, HTMLElement]> =
      original.tagName === "TR" ? Array.from(original.children as HTMLCollectionOf<HTMLElement>).map((cell, i) => [i, cell]) : [[-1, original]]
    plan.rows.set(
      index,
      targets.map(([i, target]) => [i, target.getBoundingClientRect()])
    )
    targets.forEach(([, target]) => plan.emptied.add(target))
    return true
  })
  return plan
}

// Runs in onclone, before scroll positions are restored: freezes every
// hollowed box at its rendered size and clears what html2canvas still put
// inside (pseudo elements, text). Works on a complete clone too.
export function applyHollowing(plan: HollowPlan, clonedDoc: Document) {
  if (walkCandidates(clonedDoc, (_clone, index) => plan.rows.has(index)) !== plan.survivors) return false
  // Collect first: emptying an element mid-walk would detach the opted-in
  // elements inside it, and the walk would no longer see them as nested.
  const work: Array<[HTMLElement, DOMRect]> = []
  walkCandidates(clonedDoc, (clone, index) => {
    const boxes = plan.rows.get(index)
    if (!boxes) return false
    boxes.forEach(([cellIndex, rect]) => {
      const target = cellIndex === -1 ? clone : (clone.children[cellIndex] as HTMLElement | undefined)
      if (target) work.push([target, rect])
    })
    return true
  })
  work.forEach(([target, rect]) => freezeAndEmpty(target, rect))
  return true
}

// Plan and apply in one step against an already complete clone.
export function hollowOffscreenElements(originalDoc: Document, clonedDoc: Document, bounds: Bounds) {
  const plan = planHollowing(originalDoc, bounds)
  return applyHollowing(plan, clonedDoc) ? plan.rows.size : 0
}

function freezeAndEmpty(target: HTMLElement, rect: DOMRect) {
  const width = `${rect.width}px`
  const height = `${rect.height}px`
  target.style.setProperty("box-sizing", "border-box", "important")
  target.style.setProperty("width", width, "important")
  target.style.setProperty("min-width", width, "important")
  target.style.setProperty("max-width", width, "important")
  target.style.setProperty("height", height, "important")
  target.style.setProperty("min-height", height, "important")
  target.style.setProperty("max-height", height, "important")
  target.replaceChildren()
}

// Debug hook for the parity and timing e2e specs, installed only when the
// browser has opted in with localStorage["syrus.debug.screenshotCapture"] = "1".
export function installScreenshotCaptureDebugHook() {
  try {
    if (window.localStorage.getItem("syrus.debug.screenshotCapture") !== "1") return
  } catch {
    return
  }
  ;(window as unknown as { __syrusScreenshotCapture?: unknown }).__syrusScreenshotCapture = {
    async viewport(options: CaptureOptions = {}) {
      const html2canvas = await loadHtml2Canvas()
      return captureViewport(html2canvas, options)
    },
    hollowCandidates: () => document.querySelectorAll(`[${HOLLOW_ATTRIBUTE}]`).length,
    lastHollowedCount: () => lastHollowedCount
  }
}
