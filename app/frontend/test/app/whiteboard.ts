import { fireEvent, screen, within } from "@testing-library/react"
import { vi } from "vitest"

export async function openWhiteboardPanel() {
  await clickWhiteboardTab()
  await screen.findByRole("button", { name: "Draw on whiteboard" }, { timeout: 5000 })
}

export async function clickWhiteboardTab() {
  await screen.findByText("Discuss aqueducts.")
  const workspaceTabs = await screen.findByRole("navigation", { name: "Chat workspace tabs" }, { timeout: 5000 })
  fireEvent.click(within(workspaceTabs).getByRole("button", { name: "Whiteboard" }))
  await vi.dynamicImportSettled()
}
