import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  change() {
    const [column, direction] = this.element.value.split(":")
    if (!column || !direction) return

    const url = new URL(globalThis.location.href)
    url.searchParams.set("sort_column", column)
    url.searchParams.set("sort_direction", direction)
    globalThis.location.href = url.toString()
  }
}
