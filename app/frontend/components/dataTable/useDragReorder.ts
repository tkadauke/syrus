import { useEffect, useRef, useState } from "react"
import type { DragEvent } from "react"
import { reorderColumnKeys } from "./columnOrder"

export interface DataTableDragProps {
  draggable: true
  onDragStart: (event: DragEvent<HTMLElement>) => void
  onDragOver: (event: DragEvent<HTMLElement>) => void
  onDrop: (event: DragEvent<HTMLElement>) => void
  onDragEnd: () => void
}

// Native HTML5 drag-and-drop reordering over an ordered list of string keys,
// shared between the column picker menu (reordering rows) and the table
// header row (reordering columns) so both behave identically. Mirrors the
// drag pattern already used for saved smart-folder reordering
// (DashboardSmartFolderNav / SmartFolderNavigation): the rendered order
// updates live as the dragged item crosses another item, but the reorder is
// only committed (onReorder called) on drop -- crossing five columns before
// releasing the mouse should persist once, not five times.
//
// This hook is a mouse-only convenience layer on top of whatever order state
// the caller already exposes through accessible controls (e.g. the picker
// menu's move up/down buttons) -- native drag-and-drop has no keyboard
// equivalent, so callers must keep a non-drag fallback for reordering.
export function useDragReorder<TKey extends string>({
  disabled = false,
  keys,
  onReorder
}: {
  disabled?: boolean
  keys: TKey[]
  onReorder: (nextKeys: TKey[]) => void
}) {
  const [ liveOrder, setLiveOrder ] = useState<TKey[] | null>(null)
  const [ dragOverKey, setDragOverKey ] = useState<TKey | null>(null)
  const dragKeyRef = useRef<TKey | null>(null)
  const liveOrderRef = useRef<TKey[] | null>(null)

  // An external order change while nothing is being dragged (e.g. the
  // persisted preference reloaded) drops any stale live copy.
  useEffect(() => {
    if (dragKeyRef.current == null) setLiveOrder(null)
  }, [ keys ])

  function clear() {
    dragKeyRef.current = null
    liveOrderRef.current = null
    setLiveOrder(null)
    setDragOverKey(null)
  }

  function dragProps(key: TKey): Partial<DataTableDragProps> {
    if (disabled) return {}

    return {
      draggable: true,
      onDragStart: (event: DragEvent<HTMLElement>) => {
        dragKeyRef.current = key
        liveOrderRef.current = keys
        event.dataTransfer.effectAllowed = "move"
        event.dataTransfer.setData("text/plain", key)
      },
      onDragOver: (event: DragEvent<HTMLElement>) => {
        const source = dragKeyRef.current
        if (source == null) return

        event.preventDefault()
        event.dataTransfer.dropEffect = "move"
        setDragOverKey(key)
        if (source === key) return

        const current = liveOrderRef.current ?? keys
        const next = reorderColumnKeys(current, source, key)
        if (next === current) return

        liveOrderRef.current = next
        setLiveOrder(next)
      },
      onDrop: (event: DragEvent<HTMLElement>) => {
        event.preventDefault()
        const result = liveOrderRef.current
        clear()
        if (result) onReorder(result)
      },
      onDragEnd: clear
    }
  }

  return { dragOverKey, dragProps, isDragging: dragKeyRef.current != null, order: liveOrder ?? keys }
}
