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
    this.tagName = tagName
    this.children = []
    this.dataset = {}
    this.attributes = {}
    this.className = ""
    this.type = ""
    this.title = ""
    this._textContent = ""
  }

  append(...children) {
    children.forEach((child) => this.children.push(child))
  }

  replaceChildren(...children) {
    this.children = children
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
}

function installDocument() {
  globalThis.document = {
    createElement: (tagName) => new Element(tagName),
    createTextNode: (text) => text
  }
}

function buildController(Controller, { tree, schema }) {
  installDocument()

  const controller = new Controller()
  controller.treeValue = tree
  controller.schemaValue = schema
  controller.chipsTarget = new Element()
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
