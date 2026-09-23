import { act, renderHook } from "@testing-library/react"
import type { DragEvent } from "react"
import { describe, expect, it, vi } from "vitest"
import { useDragReorder } from "./useDragReorder"

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

function dragEvent(transfer: ReturnType<typeof dataTransfer>): DragEvent<HTMLElement> {
  return { dataTransfer: transfer, preventDefault: vi.fn() } as unknown as DragEvent<HTMLElement>
}

describe("useDragReorder", () => {
  it("reorders live as the dragged key crosses another key, then commits once on drop", () => {
    const onReorder = vi.fn()
    const { result } = renderHook(() => useDragReorder({ keys: [ "a", "b", "c" ], onReorder }))
    const transfer = dataTransfer()

    act(() => {
      result.current.dragProps("a").onDragStart?.(dragEvent(transfer))
    })
    act(() => {
      result.current.dragProps("c").onDragOver?.(dragEvent(transfer))
    })

    expect(result.current.order).toEqual([ "b", "c", "a" ])
    expect(onReorder).not.toHaveBeenCalled()

    act(() => {
      result.current.dragProps("c").onDrop?.(dragEvent(transfer))
    })

    expect(onReorder).toHaveBeenCalledTimes(1)
    expect(onReorder).toHaveBeenCalledWith([ "b", "c", "a" ])
  })

  // Regression: picking up an item and dropping it back on itself (a
  // hesitant drag, or the user changing their mind) without ever crossing
  // another item must not commit a no-op reorder.
  it("does not call onReorder when the drag is dropped without crossing another item", () => {
    const onReorder = vi.fn()
    const { result } = renderHook(() => useDragReorder({ keys: [ "a", "b", "c" ], onReorder }))
    const transfer = dataTransfer()

    act(() => {
      result.current.dragProps("a").onDragStart?.(dragEvent(transfer))
    })
    act(() => {
      result.current.dragProps("a").onDrop?.(dragEvent(transfer))
    })

    expect(onReorder).not.toHaveBeenCalled()
    expect(result.current.order).toEqual([ "a", "b", "c" ])
  })

  it("does not call onReorder when dragover only ever re-crosses the origin key", () => {
    const onReorder = vi.fn()
    const { result } = renderHook(() => useDragReorder({ keys: [ "a", "b", "c" ], onReorder }))
    const transfer = dataTransfer()

    act(() => {
      result.current.dragProps("a").onDragStart?.(dragEvent(transfer))
    })
    act(() => {
      // Hovering back over the source key itself is a same-key no-op.
      result.current.dragProps("a").onDragOver?.(dragEvent(transfer))
    })
    act(() => {
      result.current.dragProps("a").onDrop?.(dragEvent(transfer))
    })

    expect(onReorder).not.toHaveBeenCalled()
  })

  it("does nothing when dragProps is called while disabled", () => {
    const onReorder = vi.fn()
    const { result } = renderHook(() => useDragReorder({ disabled: true, keys: [ "a", "b" ], onReorder }))

    expect(result.current.dragProps("a")).toEqual({})
  })
})
