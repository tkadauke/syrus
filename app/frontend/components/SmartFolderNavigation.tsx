import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { DragEvent, FocusEvent, KeyboardEvent, MouseEvent, ReactNode } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { Link, useNavigate } from "react-router-dom"
import { deleteSmartFolder, updateSmartFolder } from "../api/smartFolders"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { withRoutePrefix } from "../lib/routing"
import { Input } from "./Input"

export type SmartFolderNavFolder = {
  id: number
  name: string
  kind: string
  visibility: string
  position: number
  count: number | null
  active: boolean
  path: string
}

export type SmartFolderNavAllLink = {
  active: boolean
  label: string
  onSelect?: () => void
  path: string
}

export function SmartFolderNavigation<TFolder extends SmartFolderNavFolder>({
  actionLabel,
  allLink,
  ariaLabel,
  emptySavedMessage,
  getDisplayName,
  heading,
  moreLabel,
  onMutationSuccess,
  onSelect,
  prefix,
  queryKey,
  renderCountPrefix,
  savedAriaLabel,
  savedHeading,
  folders
}: {
  actionLabel: (folder: TFolder) => string
  allLink?: SmartFolderNavAllLink | null
  ariaLabel: string
  emptySavedMessage: string
  folders: TFolder[]
  getDisplayName: (folder: TFolder) => string
  heading?: string | null
  moreLabel: string
  onMutationSuccess?: () => void
  onSelect?: (folder: TFolder) => void
  prefix: string
  queryKey?: unknown[]
  renderCountPrefix?: (folder: TFolder) => ReactNode
  savedAriaLabel: string
  savedHeading: string
}) {
  const builtinFolders = useMemo(() => folders.filter((folder) => folder.kind !== "user_defined"), [folders])
  const primaryFolders = useMemo(() => builtinFolders.filter((folder) => folder.visibility !== "on_demand"), [builtinFolders])
  const moreFolders = useMemo(() => builtinFolders.filter((folder) => folder.visibility === "on_demand"), [builtinFolders])
  const savedFolders = useMemo(() => folders.filter((folder) => folder.kind === "user_defined"), [folders])
  const [orderedSavedFolders, setOrderedSavedFolders] = useState(savedFolders)
  const [isReordering, setIsReordering] = useState(false)
  const orderedSavedFoldersRef = useRef(savedFolders)
  const dragIndex = useRef<number | null>(null)
  const savedFolderPositions = useMemo(() => new Map(savedFolders.map((folder, index) => [folder.id, folder.position ?? index])), [savedFolders])

  useEffect(() => {
    setOrderedSavedFolders(savedFolders)
    orderedSavedFoldersRef.current = savedFolders
  }, [savedFolders])

  function startSavedFolderDrag(index: number, event: DragEvent<HTMLElement>) {
    dragIndex.current = index
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", String(orderedSavedFoldersRef.current[index]?.id ?? ""))
  }

  function dragOverSavedFolder(index: number, event: DragEvent<HTMLElement>) {
    const sourceIndex = dragIndex.current
    if (sourceIndex == null) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    if (sourceIndex === index) return

    const nextFolders = reorderFolders(orderedSavedFoldersRef.current, sourceIndex, index)
    orderedSavedFoldersRef.current = nextFolders
    dragIndex.current = index
    setOrderedSavedFolders(nextFolders)
  }

  async function dropSavedFolder(event: DragEvent<HTMLElement>) {
    if (dragIndex.current == null) return

    event.preventDefault()
    const reorderedFolders = orderedSavedFoldersRef.current
    clearSavedFolderDrag()
    const changedFolders = reorderedFolders.filter((folder, index) => savedFolderPositions.get(folder.id) !== index)
    if (changedFolders.length === 0) return

    setIsReordering(true)
    try {
      await Promise.all(changedFolders.map((folder) => {
        const position = reorderedFolders.findIndex((candidate) => candidate.id === folder.id)
        return updateSmartFolder(folder.id, { name: folder.name, position })
      }))
      onMutationSuccess?.()
    } finally {
      setIsReordering(false)
    }
  }

  function clearSavedFolderDrag() {
    dragIndex.current = null
  }

  return (
    <aside className="space-y-2">
      {heading ? <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{heading}</h2> : null}
      <nav aria-label={ariaLabel} className="space-y-1">
        {allLink ? (
          <Link className={smartFolderRowClass(allLink.active)} onClick={allLink.onSelect} to={withRoutePrefix(allLink.path, prefix)}>
            <span className="truncate">{allLink.label}</span>
          </Link>
        ) : null}
        {primaryFolders.map((folder) => (
          <SmartFolderRow
            actionLabel={actionLabel}
            folder={folder}
            getDisplayName={getDisplayName}
            key={folder.id}
            onMutationSuccess={onMutationSuccess}
            onSelect={onSelect}
            prefix={prefix}
            queryKey={queryKey}
            renderCountPrefix={renderCountPrefix}
          />
        ))}
        {moreFolders.length > 0 ? (
          <details className="space-y-1" open={moreFolders.some((folder) => folder.active) || undefined}>
            <summary className="list-none cursor-pointer px-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{moreLabel}</summary>
            <div className="space-y-1">
              {moreFolders.map((folder) => (
                <SmartFolderRow
                  actionLabel={actionLabel}
                  folder={folder}
                  getDisplayName={getDisplayName}
                  key={folder.id}
                  onMutationSuccess={onMutationSuccess}
                  onSelect={onSelect}
                  prefix={prefix}
                  queryKey={queryKey}
                  renderCountPrefix={renderCountPrefix}
                />
              ))}
            </div>
          </details>
        ) : null}
      </nav>
      <div className="space-y-1 pt-3">
        <h3 className="px-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{savedHeading}</h3>
        {savedFolders.length > 0 ? (
          <nav aria-label={savedAriaLabel} className="space-y-1">
            {orderedSavedFolders.map((folder, index) => (
              <SmartFolderRow
                actionLabel={actionLabel}
                draggable={!isReordering}
                folder={folder}
                getDisplayName={getDisplayName}
                key={folder.id}
                onDragEnd={clearSavedFolderDrag}
                onDragOver={(event) => dragOverSavedFolder(index, event)}
                onDragStart={(event) => startSavedFolderDrag(index, event)}
                onDrop={dropSavedFolder}
                onMutationSuccess={onMutationSuccess}
                onSelect={onSelect}
                prefix={prefix}
                queryKey={queryKey}
                renderCountPrefix={renderCountPrefix}
                showDragHandle
              />
            ))}
          </nav>
        ) : (
          <p className="px-2 py-1.5 text-sm text-gray-400 dark:text-gray-500">{emptySavedMessage}</p>
        )}
      </div>
    </aside>
  )
}

function SmartFolderRow<TFolder extends SmartFolderNavFolder>({
  actionLabel,
  draggable = false,
  folder,
  getDisplayName,
  onDragEnd,
  onDragOver,
  onDragStart,
  onDrop,
  onMutationSuccess,
  onSelect,
  prefix,
  queryKey,
  renderCountPrefix,
  showDragHandle = false
}: {
  actionLabel: (folder: TFolder) => string
  draggable?: boolean
  folder: TFolder
  getDisplayName: (folder: TFolder) => string
  onDragEnd?: () => void
  onDragOver?: (event: DragEvent<HTMLElement>) => void
  onDragStart?: (event: DragEvent<HTMLElement>) => void
  onDrop?: (event: DragEvent<HTMLElement>) => void
  onMutationSuccess?: () => void
  onSelect?: (folder: TFolder) => void
  prefix: string
  queryKey?: unknown[]
  renderCountPrefix?: (folder: TFolder) => ReactNode
  showDragHandle?: boolean
}) {
  const { t } = useT("nav")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [menuOpen, setMenuOpen] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [name, setName] = useState(folder.name)
  const [deleteArmed, setDeleteArmed] = useState(false)
  const [actionsVisible, setActionsVisible] = useState(false)
  const [menuAnchor, setMenuAnchor] = useState<{ top: number; right: number } | null>(null)
  const ignoreNextBlurRef = useRef(false)
  const buttonRef = useRef<HTMLButtonElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  const popupRef = useRef<HTMLDivElement>(null)
  const displayName = getDisplayName(folder)

  function closeMenu() {
    setMenuOpen(false)
    setDeleteArmed(false)
    setMenuAnchor(null)
  }

  useEffect(() => {
    if (!menuOpen) return

    function closeOnEscape(event: globalThis.KeyboardEvent) {
      if (event.key === "Escape") closeMenu()
    }

    function closeOnOutsidePointer(event: PointerEvent) {
      const target = event.target
      if (!(target instanceof Node)) return
      if (buttonRef.current?.contains(target) || menuRef.current?.contains(target)) return

      closeMenu()
    }

    window.addEventListener("keydown", closeOnEscape)
    window.addEventListener("pointerdown", closeOnOutsidePointer)
    return () => {
      window.removeEventListener("keydown", closeOnEscape)
      window.removeEventListener("pointerdown", closeOnOutsidePointer)
    }
  }, [menuOpen])

  const update = useMutation({
    mutationFn: () => updateSmartFolder(folder.id, { name: name.trim(), position: folder.position }),
    onSuccess: () => {
      setRenaming(false)
      closeMenu()
      if (queryKey) void queryClient.invalidateQueries({ queryKey })
      onMutationSuccess?.()
    }
  })
  const destroy = useMutation({
    mutationFn: () => deleteSmartFolder(folder.id),
    onSuccess: () => {
      closeMenu()
      if (queryKey) void queryClient.invalidateQueries({ queryKey })
      onMutationSuccess?.()
    }
  })

  function startRename() {
    setName(folder.name)
    setRenaming(true)
    closeMenu()
    update.reset()
  }

  function confirmRename() {
    if (update.isPending || name.trim().length === 0) return
    update.mutate()
  }

  function cancelRename() {
    setName(folder.name)
    setRenaming(false)
    update.reset()
  }

  function handleRenameKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "Enter") {
      event.preventDefault()
      confirmRename()
    } else if (event.key === "Escape") {
      event.preventDefault()
      ignoreNextBlurRef.current = true
      cancelRename()
    }
  }

  function handleBlur(event: FocusEvent<HTMLDivElement>) {
    if (!event.currentTarget.contains(event.relatedTarget)) {
      setActionsVisible(false)
    }
  }

  function toggleMenu() {
    destroy.reset()
    setDeleteArmed(false)
    setMenuOpen((open) => {
      if (open) {
        setMenuAnchor(null)
        return false
      }

      const rect = buttonRef.current?.getBoundingClientRect()
      if (rect) setMenuAnchor({ top: rect.bottom + 4, right: window.innerWidth - rect.right })
      return true
    })
  }

  if (folder.kind !== "user_defined") {
    const countPrefix = renderCountPrefix?.(folder)
    const href = withRoutePrefix(folder.path, prefix)
    const label = smartFolderLabel(displayName, folder.count)
    const selectFolder = () => onSelect?.(folder)

    if (!countPrefix) {
      return (
        <Link
          aria-label={label}
          className={smartFolderRowClass(folder.active, showDragHandle)}
          draggable={false}
          onClick={selectFolder}
          to={href}
        >
          {showDragHandle ? <GripIcon /> : null}
          <span className="min-w-0 flex-1 truncate">{displayName}</span>
          <FolderCount active={folder.active} count={folder.count} />
        </Link>
      )
    }

    return (
      <div
        aria-label={label}
        className={smartFolderRowClass(folder.active, showDragHandle)}
        draggable={false}
        onClick={(event) => {
          if (event.defaultPrevented || event.button !== 0 || modifiedClick(event)) return
          selectFolder()
          navigate(href)
        }}
        onKeyDown={(event) => {
          if (event.key !== "Enter" && event.key !== " ") return
          event.preventDefault()
          selectFolder()
          navigate(href)
        }}
        role="link"
        tabIndex={0}
      >
        {showDragHandle ? <GripIcon /> : null}
        <span className="min-w-0 flex-1 truncate">{displayName}</span>
        <FolderCount active={folder.active} count={folder.count} prefixContent={countPrefix} />
      </div>
    )
  }

  const error = update.isError ? errorMessage(update.error, t("smart_folder.unable_to_rename")) : destroy.isError ? errorMessage(destroy.error, t("smart_folder.unable_to_delete")) : null
  const showActions = actionsVisible || menuOpen

  return (
    <div className="space-y-1">
      <div
        ref={popupRef}
        className={`relative flex min-w-0 items-center gap-1 rounded ${showDragHandle ? "group -ml-4 cursor-grab pl-4 active:cursor-grabbing" : ""} ${folder.active ? "bg-brand/10 font-medium text-brand dark:text-brand-emphasis" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`}
        draggable={draggable}
        onBlur={handleBlur}
        onDragEnd={onDragEnd}
        onDragOver={onDragOver}
        onDragStart={onDragStart}
        onDrop={onDrop}
        onFocus={() => setActionsVisible(true)}
        onMouseEnter={() => setActionsVisible(true)}
        onMouseLeave={() => {
          if (!menuOpen) setActionsVisible(false)
        }}
      >
        {renaming ? (
          <div className="flex min-w-0 flex-1 items-center justify-between gap-2 rounded-l px-2 py-1.5 text-sm">
            <Input
              aria-label={`Rename ${folder.name}`}
              autoFocus
              className="min-w-0 flex-1"
              disabled={update.isPending}
              maxLength={120}
              onBlur={() => {
                if (ignoreNextBlurRef.current) {
                  ignoreNextBlurRef.current = false
                  return
                }
                confirmRename()
              }}
              onChange={(event) => setName(event.target.value)}
              onKeyDown={handleRenameKeyDown}
              value={name}
            />
          </div>
        ) : (
          <Link aria-label={smartFolderLabel(folder.name, folder.count)} className="flex min-w-0 flex-1 items-center gap-2 rounded-l px-2 py-1.5 text-sm" onClick={() => onSelect?.(folder)} to={withRoutePrefix(folder.path, prefix)}>
            <span className="truncate">{folder.name}</span>
          </Link>
        )}
        {showDragHandle ? <GripIcon floating /> : null}
        <div className="mr-1 flex h-7 w-7 shrink-0 items-center justify-center">
          {showActions ? (
            <button
              ref={buttonRef}
              aria-expanded={menuOpen}
              aria-haspopup="menu"
              aria-label={actionLabel(folder)}
              className="inline-flex h-7 w-7 items-center justify-center rounded text-gray-500 hover:bg-gray-200 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-gray-100"
              onClick={(event) => {
                event.stopPropagation()
                toggleMenu()
              }}
              type="button"
            >
              ...
            </button>
          ) : (
            <FolderCount active={folder.active} count={folder.count} prefixContent={renderCountPrefix?.(folder)} />
          )}
        </div>
        {menuOpen && menuAnchor ? createPortal(
          <div
            ref={menuRef}
            className="fixed z-50 min-w-36 rounded border border-gray-200 bg-white py-1 text-sm shadow-lg dark:border-gray-700 dark:bg-gray-900"
            role="menu"
            style={{ top: menuAnchor.top, right: menuAnchor.right }}
          >
            <button className="block w-full px-3 py-1.5 text-left text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800" onClick={startRename} role="menuitem" type="button">
              {t("smart_folder.rename")}
            </button>
            <button
              className="block w-full px-3 py-1.5 text-left text-red-700 hover:bg-red-50 dark:text-red-300 dark:hover:bg-red-950"
              disabled={destroy.isPending}
              onClick={() => {
                if (deleteArmed) {
                  destroy.mutate()
                } else {
                  setDeleteArmed(true)
                }
              }}
              role="menuitem"
              type="button"
            >
              {deleteArmed ? t("smart_folder.confirm_delete") : t("smart_folder.delete")}
            </button>
          </div>,
          document.body
        ) : null}
      </div>
      {error ? <p className="px-2 text-xs text-red-700 dark:text-red-300" role="alert">{error}</p> : null}
    </div>
  )
}

function FolderCount({ active, count, prefixContent }: { active: boolean; count: number | null; prefixContent?: ReactNode }) {
  if (count == null && !prefixContent) return null

  return (
    <div className="ml-auto flex shrink-0 items-center gap-1">
      {prefixContent}
      {count == null ? null : (
        <span className={`inline-flex min-w-6 justify-center rounded-full px-1.5 py-0.5 text-xs ${active ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{count}</span>
      )}
    </div>
  )
}

export function smartFolderRowClass(active: boolean, withDragHandle = false) {
  return `flex min-w-0 items-center justify-between gap-2 rounded px-2 py-1.5 text-sm ${withDragHandle ? "group cursor-grab active:cursor-grabbing" : ""} ${active ? "bg-brand/10 font-medium text-brand dark:text-brand-emphasis" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`
}

export function smartFolderLabel(name: string, count: number | null) {
  return count == null ? name : `${name} ${count}`
}

function reorderFolders<TFolder>(folders: TFolder[], sourceIndex: number, targetIndex: number) {
  const reordered = [...folders]
  const [moved] = reordered.splice(sourceIndex, 1)
  reordered.splice(targetIndex, 0, moved)
  return reordered
}

function modifiedClick(event: MouseEvent<HTMLElement>) {
  return event.metaKey || event.altKey || event.ctrlKey || event.shiftKey
}

function GripIcon({ floating = false }: { floating?: boolean }) {
  return (
    <svg aria-hidden="true" className={`${floating ? "pointer-events-none absolute left-0 top-1/2 -translate-y-1/2" : "-ml-1 shrink-0"} size-4 text-gray-400 opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100 dark:text-gray-500`} fill="none" viewBox="0 0 16 16">
      <circle cx="6" cy="4" fill="currentColor" r="1" />
      <circle cx="10" cy="4" fill="currentColor" r="1" />
      <circle cx="6" cy="8" fill="currentColor" r="1" />
      <circle cx="10" cy="8" fill="currentColor" r="1" />
      <circle cx="6" cy="12" fill="currentColor" r="1" />
      <circle cx="10" cy="12" fill="currentColor" r="1" />
    </svg>
  )
}
