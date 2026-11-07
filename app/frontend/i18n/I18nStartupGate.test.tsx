import { render, screen } from "@testing-library/react"
import { act } from "react"
import { expect, it } from "vitest"
import { I18nStartupGate } from "./I18nStartupGate"

it("keeps translated UI hidden until locale resources resolve", async () => {
  let resolveReady = () => {}
  const ready = new Promise<void>((resolve) => {
    resolveReady = resolve
  })

  render(
    <I18nStartupGate ready={ready}>
      <div>Translated application</div>
    </I18nStartupGate>
  )

  expect(screen.getByRole("generic", { busy: true })).toBeInTheDocument()
  expect(screen.queryByText("Translated application")).not.toBeInTheDocument()

  await act(async () => resolveReady())

  expect(screen.getByText("Translated application")).toBeInTheDocument()
})

it("renders the application when locale loading fails", async () => {
  const ready = Promise.reject(new Error("locale chunk unavailable"))

  render(
    <I18nStartupGate ready={ready}>
      <div>Application fallback</div>
    </I18nStartupGate>
  )

  expect(await screen.findByText("Application fallback")).toBeInTheDocument()
})
