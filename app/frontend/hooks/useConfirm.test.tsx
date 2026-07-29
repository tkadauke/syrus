import { act, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { useConfirm } from "./useConfirm"

function Probe({ onResult }: { onResult?: (v: boolean) => void }) {
  const { confirm, dialog } = useConfirm()
  return (
    <div>
      <button
        onClick={() => confirm({ message: "Are you sure?" }).then((v) => onResult?.(v))}
        type="button"
      >
        open
      </button>
      {dialog}
    </div>
  )
}

describe("useConfirm", () => {
  it("resolves true when the confirm button is clicked", async () => {
    const onResult = (v: boolean) => { result = v }
    let result: boolean | undefined

    render(<Probe onResult={onResult} />)

    act(() => screen.getByRole("button", { name: "open" }).click())
    expect(screen.getByRole("dialog")).toBeInTheDocument()

    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(result).toBe(true)
  })

  it("resolves false when the cancel button is clicked", async () => {
    let result: boolean | undefined
    const onResult = (v: boolean) => { result = v }

    render(<Probe onResult={onResult} />)

    act(() => screen.getByRole("button", { name: "open" }).click())
    expect(screen.getByRole("dialog")).toBeInTheDocument()

    await act(async () => screen.getByRole("button", { name: "Cancel" }).click())

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(result).toBe(false)
  })

  it("passes options to the dialog", () => {
    const { confirm, dialog } = (() => {
      let captured: ReturnType<typeof useConfirm> | undefined
      function Hook() {
        captured = useConfirm()
        return <>{captured.dialog}</>
      }
      render(<Hook />)
      return captured!
    })()

    act(() => { confirm({ message: "Delete it?", confirmLabel: "Yes, delete", destructive: true }) })

    expect(screen.getByText("Delete it?")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Yes, delete" }).className).toContain("bg-red-600")
  })
})
