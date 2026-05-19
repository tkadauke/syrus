import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/chip_bar_controller.js", import.meta.url)

async function loadController() {
  const source = await readFile(controllerPath, "utf8")
  const testableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace("export default class extends Controller", "class ChipBarController extends Controller")

  return import(`data:text/javascript,${encodeURIComponent(`${testableSource}\nexport default ChipBarController`)}`)
}

class Element {
  constructor(tagName = "div") {
    this.tagName = tagName.toUpperCase()
    this.children = []
    this.dataset = {}
    this.attributes = {}
    this.className = ""
    this.type = ""
    this.title = ""
    this.value = ""
    this.parentElement = null
    this._textContent = ""
    this.classList = {
      add: (...names) => {
        const current = new Set(this.className.split(/\s+/).filter(Boolean))
        names.forEach((name) => current.add(name))
        this.className = Array.from(current).join(" ")
      },
      remove: (...names) => {
        const remove = new Set(names)
        this.className = this.className.split(/\s+/).filter((name) => !remove.has(name)).join(" ")
      },
      contains: (name) => this.className.split(/\s+/).includes(name)
    }
  }

  append(...children) {
    children.forEach((child) => {
      if (child instanceof Element) child.parentElement = this
      this.children.push(child)
    })
  }

  replaceChildren(...children) {
    this.children.forEach((child) => {
      if (child instanceof Element) child.parentElement = null
    })
    this.children = children
    children.forEach((child) => {
      if (child instanceof Element) child.parentElement = this
    })
  }

  setAttribute(name, value) {
    this.attributes[name] = value
  }

  get textContent() {
    return [
      this._textContent,
      ...this.children.map((child) => typeof child === "string" ? child : child.textContent)
    ].join("")
  }

  set textContent(value) {
    this._textContent = value
    this.children = []
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null
  }

  querySelectorAll(selector) {
    const matches = []
    const visit = (node) => {
      if (!(node instanceof Element)) return
      if (matchesSelector(node, selector)) matches.push(node)
      node.children.forEach(visit)
    }
    this.children.forEach(visit)
    return matches
  }

  closest(selector) {
    let node = this
    while (node) {
      if (matchesSelector(node, selector)) return node
      node = node.parentElement
    }
    return null
  }

  contains(other) {
    if (other === this) return true
    return this.children.some((child) => child instanceof Element && child.contains(other))
  }

  getBoundingClientRect() {
    return { top: 0, left: 0, bottom: 0 }
  }

  focus() {}
}

function matchesSelector(element, selector) {
  const dataRole = selector.match(/^(?:([a-z]+))?\[data-role=['"]([^'"]+)['"]\]$/)
  if (dataRole) {
    const tag = dataRole[1]
    return (!tag || element.tagName.toLowerCase() === tag) && element.dataset.role === dataRole[2]
  }

  const dataChipPath = selector.match(/^\[data-chip-path='(.+)'\]$/)
  if (dataChipPath) return element.dataset.chipPath === dataChipPath[1]

  return false
}

function installDocument() {
  globalThis.Element = Element
  globalThis.document = {
    createElement: (tagName) => new Element(tagName),
    createTextNode: (text) => text,
    addEventListener() {},
    removeEventListener() {}
  }
}

function buildController(Controller, { tree, schema }) {
  installDocument()

  const controller = new Controller()
  controller.element = new Element()
  controller.treeValue = tree
  controller.schemaValue = schema
  controller.qInputTarget = new Element("input")
  controller.formTarget = new Element("form")
  controller.formTarget.requestSubmit = () => {}
  controller.chipsTarget = new Element()
  controller.hasChipsTarget = true
  return controller
}

test("renders foreign-key chips with schema labels when URL values are strings", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller, {
    tree: { and: [ { field: "repository_id", op: "is", value: "3" } ] },
    schema: [
      {
        field: "repository_id",
        label: "Repository",
        bucket: "fk",
        operators: [ "is" ],
        values: [ { value: 3, label: "tkadauke/raytracer" } ]
      }
    ]
  })

  controller.renderChips()

  assert.match(controller.chipsTarget.textContent, /Repositoryistkadauke\/raytracer/)
  assert.doesNotMatch(controller.chipsTarget.textContent, /Repositoryis3/)
})

test("fetches labels for typeahead chip values on initial render", async () => {
  const { default: Controller } = await loadController()
  const originalFetch = globalThis.fetch
  const calls = []
  globalThis.fetch = async (url) => {
    calls.push(url)
    return {
      ok: true,
      json: async () => [ { value: 123, label: "#42 Add greeting" } ]
    }
  }

  try {
    const controller = buildController(Controller, {
      tree: { and: [ { field: "job_id", op: "is", value: "123" } ] },
      schema: [
        {
          field: "job_id",
          label: "Job",
          bucket: "fk",
          operators: [ "is" ],
          typeahead: true
        }
      ]
    })

    controller.renderChips()
    await new Promise((resolve) => setTimeout(resolve, 0))

    assert.equal(calls.length, 1)
    assert.match(calls[0], /\/filters\/fk_options\?/)
    assert.match(calls[0], /field=job_id/)
    assert.match(calls[0], /ids%5B%5D=123/)
    assert.match(controller.chipsTarget.textContent, /#42 Add greeting/)
  } finally {
    globalThis.fetch = originalFetch
  }
})

test("renders a top-level OR tree as ordinary removable chips", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller, {
    tree: {
      or: [
        { field: "state", op: "is_one_of", value: [ "queued", "running" ] },
        { field: "finished_at", op: "within_last", value: { n: 7, unit: "days" } }
      ]
    },
    schema: workflowSchema()
  })

  controller.renderChips()

  assert.match(controller.chipsTarget.textContent, /Stateis any ofQueued, Running/)
  assert.match(controller.chipsTarget.textContent, /Finishedwithin last7 days/)
  assert.match(controller.chipsTarget.textContent, /or/)
  assert.equal(controller.chipsTarget.querySelectorAll("[data-chip-path='[0,0]']").length, 2)
  assert.equal(controller.chipsTarget.querySelectorAll("[data-chip-path='[0,1]']").length, 2)
})

test("removing chips from a top-level OR tree writes an explicit q tree", async () => {
  const { default: Controller } = await loadController()
  const controller = buildController(Controller, {
    tree: {
      or: [
        { field: "state", op: "is_one_of", value: [ "queued", "running" ] },
        { field: "finished_at", op: "within_last", value: { n: 7, unit: "days" } }
      ]
    },
    schema: workflowSchema()
  })
  const submissions = []
  controller.formTarget.requestSubmit = () => submissions.push(decodeTree(controller.qInputTarget.value))

  controller.removeChip({ currentTarget: { dataset: { chipPath: "[0,0]" } } })

  assert.deepEqual(submissions.at(-1), {
    and: [ { field: "finished_at", op: "within_last", value: { n: 7, unit: "days" } } ]
  })

  controller.removeChip({ currentTarget: { dataset: { chipPath: "[0]" } } })

  assert.deepEqual(submissions.at(-1), { and: [] })
})

test("debounces rapid typeahead input into one search request", async () => {
  const { default: Controller } = await loadController()
  const originalFetch = globalThis.fetch
  const calls = []
  globalThis.fetch = async (url) => {
    calls.push(url)
    return { ok: true, json: async () => [] }
  }

  try {
    installDocument()
    const controller = new Controller()
    controller.typeaheadSearchSeq = 0
    const wrapper = typeaheadWrapper()
    const input = wrapper.querySelector("[data-role='typeahead-search']")

    input.value = "a"
    controller.typeaheadSearchInput({ currentTarget: input })
    input.value = "ad"
    controller.typeaheadSearchInput({ currentTarget: input })
    input.value = "add"
    controller.typeaheadSearchInput({ currentTarget: input })

    await new Promise((resolve) => setTimeout(resolve, 260))
    await Promise.resolve()

    assert.equal(calls.length, 1)
    assert.match(calls[0], /q=add/)
  } finally {
    globalThis.fetch = originalFetch
  }
})

test("typeahead keyboard navigation can select a result", async () => {
  const { default: Controller } = await loadController()
  installDocument()
  const controller = new Controller()
  controller.schemaValue = [
    { field: "job_id", label: "Job", bucket: "fk", operators: [ "is" ], typeahead: true }
  ]
  const wrapper = typeaheadWrapper()
  const list = wrapper.querySelector("[data-role='typeahead-options']")
  const first = optionElement("1", "#1 First")
  const second = optionElement("2", "#2 Second")
  let clicked = false
  second.click = () => {
    clicked = true
    controller.selectTypeaheadOption({ currentTarget: second, stopPropagation() {} })
  }
  list.replaceChildren(first, second)

  const input = wrapper.querySelector("[data-role='typeahead-search']")
  controller.typeaheadKeydown({ currentTarget: input, key: "ArrowDown", preventDefault() {} })
  controller.typeaheadKeydown({ currentTarget: input, key: "Enter", preventDefault() {} })

  assert.equal(clicked, true)
  assert.equal(wrapper.dataset.selected, JSON.stringify([ "2" ]))
})

test("typeahead renders an error state when the search request fails", async () => {
  const { default: Controller } = await loadController()
  const originalFetch = globalThis.fetch
  globalThis.fetch = async () => ({ ok: false, status: 500 })

  try {
    installDocument()
    const controller = new Controller()
    controller.typeaheadSearchSeq = 0
    const wrapper = typeaheadWrapper()

    controller.fetchTypeaheadSearch(wrapper)
    await new Promise((resolve) => setTimeout(resolve, 0))

    assert.match(wrapper.textContent, /Options unavailable/)
  } finally {
    globalThis.fetch = originalFetch
  }
})

test("turbo morph refreshes chips from the tree data attribute", async () => {
  const { default: Controller } = await loadController()
  const listeners = new Map()

  const controller = buildController(Controller, {
    tree: { and: [ { field: "state", op: "is", value: "queued" } ] },
    schema: [
      {
        field: "state",
        label: "State",
        bucket: "enum",
        operators: [ "is" ],
        values: [ { value: "queued", label: "Queued" }, { value: "running", label: "Running" } ]
      }
    ]
  })
  controller.element.dataset.chipBarTreeValue = JSON.stringify({ and: [ { field: "state", op: "is", value: "running" } ] })
  controller.addMenuTarget = new Element()
  controller.editorTarget = new Element()
  controller.hasAddMenuTarget = true
  controller.hasEditorTarget = true
  globalThis.document.addEventListener = (name, listener) => listeners.set(name, listener)
  globalThis.document.removeEventListener = () => {}

  controller.connect()
  listeners.get("turbo:morph")()

  assert.deepEqual(controller.treeValue, { and: [ { field: "state", op: "is", value: "running" } ] })
  assert.match(controller.chipsTarget.textContent, /StateisRunning/)
})

test("open popovers prevent Turbo element morphs", async () => {
  const { default: Controller } = await loadController()
  const listeners = new Map()

  const controller = buildController(Controller, {
    tree: { and: [] },
    schema: []
  })
  controller.addMenuTarget = new Element()
  controller.editorTarget = new Element()
  controller.hasAddMenuTarget = true
  controller.hasEditorTarget = true
  controller.element.append(controller.addMenuTarget, controller.editorTarget)
  controller.addMenuTarget.className = "absolute"
  globalThis.document.addEventListener = (name, listener) => listeners.set(name, listener)
  globalThis.document.removeEventListener = () => {}
  let prevented = false

  controller.connect()
  listeners.get("turbo:before-morph-element")({
    target: controller.addMenuTarget,
    preventDefault() { prevented = true }
  })

  assert.equal(prevented, true)
})

function typeaheadWrapper() {
  const wrapper = new Element("div")
  wrapper.dataset.role = "typeahead"
  wrapper.dataset.field = "job_id"
  wrapper.dataset.multi = "false"
  wrapper.dataset.selected = "[]"
  wrapper.dataset.activeIndex = "0"

  const selected = new Element("div")
  selected.dataset.role = "typeahead-selected"
  const input = new Element("input")
  input.dataset.role = "typeahead-search"
  const list = new Element("div")
  list.dataset.role = "typeahead-options"
  wrapper.append(selected, input, list)
  return wrapper
}

function optionElement(value, label) {
  const option = new Element("button")
  option.dataset.role = "typeahead-option"
  option.dataset.value = value
  option.textContent = label
  return option
}

function workflowSchema() {
  return [
    {
      field: "state",
      label: "State",
      bucket: "enum",
      operators: [ "is", "is_one_of" ],
      values: [
        { value: "queued", label: "Queued" },
        { value: "running", label: "Running" }
      ]
    },
    {
      field: "finished_at",
      label: "Finished",
      bucket: "date",
      operators: [ "within_last" ]
    }
  ]
}

function decodeTree(encoded) {
  const base64 = encoded.replace(/-/g, "+").replace(/_/g, "/")
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")
  return JSON.parse(Buffer.from(padded, "base64").toString("utf8"))
}
