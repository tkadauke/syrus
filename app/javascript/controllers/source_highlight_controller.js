import { Controller } from "@hotwired/stimulus"

// Applies highlight.js syntax highlighting to the connected <code> element.
// Fires on connect so it runs both on initial Turbo Frame load and on
// subsequent frame navigations (new file selected, commit changed, etc.).
export default class extends Controller {
  connect() {
    if (window.hljs) {
      window.hljs.highlightElement(this.element)
    }
  }
}
