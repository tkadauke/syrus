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
      this.descriptionTarget.value = ""
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

  async submit(event) {
    event.preventDefault()

    if (!this.syncSelectedScreenshot()) {
      window.alert("Choose a screenshot before submitting.")
      return
    }

    try {
      const response = await fetch(this.formTarget.action, {
        method: this.formTarget.method.toUpperCase(),
        body: new FormData(this.formTarget),
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        credentials: "same-origin"
      })
      const payload = await response.json()

      if (response.ok) {
        this.close()
        this.showFlash(payload.message || "Bug report queued.", "notice")
      } else {
        window.alert(payload.error || "Bug report could not be queued.")
      }
    } catch (error) {
      window.alert("Bug report could not be queued.")
      console.error(error)
    }
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
    if (this.hasNoneRadioTarget && this.noneRadioTarget.checked) {
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

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  showFlash(message, kind) {
    const id = kind === "alert" ? "alert" : "notice"
    const existing = document.getElementById(id)
    const flash = existing || document.createElement("p")
    flash.id = id
    flash.dataset.controller = "flash"
    flash.className = kind === "alert"
      ? "py-2 px-3 bg-red-50 mb-5 text-red-500 font-medium rounded-lg inline-block"
      : "py-2 px-3 bg-green-50 mb-5 text-green-500 font-medium rounded-lg inline-block"
    flash.textContent = message

    if (!existing) {
      document.querySelector("main")?.prepend(flash)
    }
  }
}
