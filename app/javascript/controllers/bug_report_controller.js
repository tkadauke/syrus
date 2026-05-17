import { Controller } from "@hotwired/stimulus"
import html2canvas from "html2canvas"

export default class extends Controller {
  static targets = [
    "button", "dialog", "form", "title", "description", "screenshotInput",
    "viewportPreview", "fullPagePreview", "viewportRadio", "fullPageRadio", "noneRadio"
  ]

  connect() {
    this.captures = {}
  }

  async open() {
    this.setButtonBusy(true)

    try {
      const [viewportCanvas, fullPageCanvas] = await Promise.all([
        this.captureViewport(),
        this.captureFullPage()
      ])

      this.captures = {
        viewport: await this.canvasToFile(viewportCanvas, "bug-report-viewport.png"),
        fullPage: await this.canvasToFile(fullPageCanvas, "bug-report-full-page.png")
      }

      this.viewportPreviewTarget.src = URL.createObjectURL(this.captures.viewport)
      this.fullPagePreviewTarget.src = URL.createObjectURL(this.captures.fullPage)
      this.viewportRadioTarget.checked = true
      this.titleTarget.value = `${this.contextLabel()} bug`
      this.syncSelectedScreenshot()
      this.dialogTarget.showModal()
    } catch (error) {
      window.alert("Screenshot capture failed. Please try again.")
      console.error(error)
    } finally {
      this.setButtonBusy(false)
    }
  }

  close() {
    this.dialogTarget.close()
  }

  choose() {
    this.syncSelectedScreenshot()
  }

  submit(event) {
    if (!this.syncSelectedScreenshot()) {
      event.preventDefault()
      window.alert("Choose a screenshot before submitting.")
      return
    }

    this.close()
  }

  captureViewport() {
    return html2canvas(document.body, {
      x: window.scrollX,
      y: window.scrollY,
      width: window.innerWidth,
      height: window.innerHeight,
      windowWidth: window.innerWidth,
      windowHeight: window.innerHeight,
      useCORS: true
    })
  }

  captureFullPage() {
    const width = Math.max(
      document.body.scrollWidth,
      document.documentElement.scrollWidth,
      window.innerWidth
    )
    const height = Math.max(
      document.body.scrollHeight,
      document.documentElement.scrollHeight,
      window.innerHeight
    )

    return html2canvas(document.body, {
      width,
      height,
      windowWidth: width,
      windowHeight: height,
      useCORS: true
    })
  }

  canvasToFile(canvas, filename) {
    return new Promise((resolve, reject) => {
      canvas.toBlob((blob) => {
        if (blob) {
          resolve(new File([blob], filename, { type: "image/png" }))
        } else {
          reject(new Error("canvas.toBlob returned nil"))
        }
      }, "image/png")
    })
  }

  syncSelectedScreenshot() {
    if (this.noneRadioTarget.checked) {
      this.screenshotInputTarget.value = ""
      return true
    }

    const selected = this.fullPageRadioTarget.checked ? this.captures.fullPage : this.captures.viewport
    if (!selected) return false

    const transfer = new DataTransfer()
    transfer.items.add(selected)
    this.screenshotInputTarget.files = transfer.files
    return true
  }

  contextLabel() {
    return this.element.dataset.bugContext || "Syrus"
  }

  setButtonBusy(busy) {
    this.buttonTarget.disabled = busy
    this.buttonTarget.classList.toggle("opacity-60", busy)
    this.buttonTarget.classList.toggle("cursor-wait", busy)
  }
}
