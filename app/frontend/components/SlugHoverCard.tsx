import { FloatingPortal, autoPlacement, flip, offset, shift, useFloating } from "@floating-ui/react"
import { type ComponentType, type KeyboardEvent as ReactKeyboardEvent, type MouseEvent, type ReactNode, Suspense, useCallback, useEffect, useRef, useState } from "react"
import { Link } from "react-router-dom"
import { pluginSlugPreviewCardComponentForPrefix, type PluginSlugPreviewCardProps } from "../pluginSlugPreviewCards"
import { hrefForSlugReference, type SlugReferenceRegistryEntry } from "../lib/slugReferenceRegistry"
import { useT } from "../hooks/useT"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"
import { CopyIcon } from "./CopyableSlug"
import { ChatPreviewCard } from "./ChatPreviewCard"
import { EpicPreviewCard } from "./EpicPreviewCard"
import { JobPreviewCard } from "./JobPreviewCard"

const corePreviewCards: Record<string, ComponentType<{ id: number; compact?: boolean }>> = {
  chat: ChatPreviewCard,
  epic: EpicPreviewCard,
  job: JobPreviewCard
}
const actionCloseButtonClassName =
  "shrink-0 rounded px-2 py-1 text-sm text-text-secondary hover:bg-surface-raised hover:text-text-primary focus:outline-none focus:ring-2 focus:ring-brand"
const actionButtonClassName =
  "inline-flex items-center gap-1 rounded border border-border bg-surface px-3 py-1.5 text-sm font-medium text-text-primary shadow-sm hover:bg-surface-raised focus:outline-none focus:ring-2 focus:ring-brand"
const actionOpenClassName =
  "inline-flex items-center rounded bg-brand px-3 py-1.5 text-sm font-medium text-white shadow-sm hover:bg-brand-emphasis focus:outline-none focus:ring-2 focus:ring-brand"

interface SlugReferenceCardProps {
  entry: SlugReferenceRegistryEntry
  id: number
  slug?: string
  children: ReactNode
}

function PluginPreviewCard({ Component, id }: { Component: ComponentType<PluginSlugPreviewCardProps> | null; id: number }) {
  if (!Component) return null

  return (
    <Suspense fallback={null}>
      <Component id={id} />
    </Suspense>
  )
}

function PreviewCard({ entry, id }: { entry: SlugReferenceRegistryEntry; id: number }) {
  const Component = corePreviewCards[entry.type]
  if (Component) return <Component id={id} />

  return <PluginPreviewCard Component={entry.pluginPreviewComponent} id={id} />
}

function detectPointerFine(): boolean {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return true

  return window.matchMedia("(hover: hover) and (pointer: fine)").matches
}

export function SlugReferenceCard({ entry, id, slug: slugProp, children }: SlugReferenceCardProps) {
  const { t } = useT("common")
  const [isOpen, setIsOpen] = useState(false)
  const [surfaceMode, setSurfaceMode] = useState<"preview" | "actions">("preview")
  const openTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  // Checked once on first render; pointer capability doesn't change during a session
  const canHover = useRef(detectPointerFine())
  const slug = slugProp ?? `${entry.prefix}-${id}`
  const href = hrefForSlugReference(entry, id)
  const hasActions = Boolean(href || entry.copyable)

  const { refs, floatingStyles } = useFloating({
    middleware: [offset(8), flip({ padding: 8 }), autoPlacement({ padding: 8 }), shift({ padding: 8 })]
  })

  const open = useCallback((mode: "preview" | "actions") => {
    if (mode === "preview" && !entry.previewAvailable) return
    if (mode === "actions" && !entry.previewAvailable && !hasActions) return
    setSurfaceMode(mode)
    setIsOpen(true)
  }, [entry.previewAvailable, hasActions])

  const close = useCallback(() => {
    setIsOpen(false)
  }, [])

  const handleReferenceEnter = useCallback(() => {
    if (!entry.previewAvailable) return
    if (!canHover.current) return
    if (closeTimer.current) clearTimeout(closeTimer.current)
    openTimer.current = setTimeout(() => open("preview"), 300)
  }, [entry.previewAvailable, open])

  const handleReferenceLeave = useCallback(() => {
    if (!entry.previewAvailable) return
    if (!canHover.current) return
    if (openTimer.current) clearTimeout(openTimer.current)
    // Small grace period so the cursor can reach the floating card
    closeTimer.current = setTimeout(() => setIsOpen(false), 100)
  }, [entry.previewAvailable])

  const handleFloatingEnter = useCallback(() => {
    if (closeTimer.current) clearTimeout(closeTimer.current)
  }, [])

  const handleFloatingLeave = useCallback(() => {
    setIsOpen(false)
  }, [])

  const handleClick = useCallback(
    (event: MouseEvent<HTMLSpanElement>) => {
      if (canHover.current) return
      if (!entry.previewAvailable && !hasActions) return

      event.preventDefault()
      event.stopPropagation()
      open("actions")
    },
    [entry.previewAvailable, hasActions, open]
  )

  const handleFocus = useCallback(() => {
    if (canHover.current) {
      open("preview")
    }
  }, [open])

  const handleKeyDown = useCallback(
    (event: ReactKeyboardEvent<HTMLSpanElement>) => {
      if (event.key !== "Enter" && event.key !== " ") return
      if (!entry.previewAvailable && !hasActions) return

      event.preventDefault()
      event.stopPropagation()
      open("actions")
    },
    [entry.previewAvailable, hasActions, open]
  )

  useEffect(() => {
    if (!isOpen) return

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target as Node
      const reference = refs.reference.current
      const floating = refs.floating.current
      if (reference instanceof Node && reference.contains(target)) return
      if (floating instanceof Node && floating.contains(target)) return

      close()
    }
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") close()
    }

    document.addEventListener("pointerdown", handlePointerDown)
    document.addEventListener("keydown", handleKeyDown)
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown)
      document.removeEventListener("keydown", handleKeyDown)
    }
  }, [close, isOpen, refs.floating, refs.reference])

  useEffect(() => {
    return () => {
      if (openTimer.current) clearTimeout(openTimer.current)
      if (closeTimer.current) clearTimeout(closeTimer.current)
    }
  }, [])

  const actionSurfaceIsBottomSheet = surfaceMode === "actions" && !canHover.current
  const wrapperIsInteractive = entry.previewAvailable && !hasActions
  const floatingClassName =
    surfaceMode === "actions"
      ? actionSurfaceIsBottomSheet
        ? "fixed inset-x-0 bottom-0 z-50 border-t border-border bg-surface p-3 shadow-2xl [&>*]:max-w-[calc(100vw-1rem)]"
        : "z-50 w-80 rounded-lg border border-border bg-surface p-2 shadow-2xl [&>*]:max-w-[calc(100vw-1rem)]"
      : "[&>*]:max-w-[calc(100vw-1rem)]"
  const floatingStyle = actionSurfaceIsBottomSheet ? undefined : { ...floatingStyles, zIndex: 50 }

  return (
    <>
      <span
        aria-expanded={wrapperIsInteractive ? isOpen : undefined}
        aria-haspopup={wrapperIsInteractive ? "dialog" : undefined}
        aria-label={wrapperIsInteractive ? t("slug_reference.surface_label", { slug }) : undefined}
        onClickCapture={handleClick}
        onFocus={handleFocus}
        onKeyDownCapture={handleKeyDown}
        onMouseEnter={handleReferenceEnter}
        onMouseLeave={handleReferenceLeave}
        ref={refs.setReference}
        role={wrapperIsInteractive ? "button" : undefined}
        style={{ display: "inline" }}
        tabIndex={wrapperIsInteractive ? 0 : undefined}
      >
        {children}
      </span>
      {isOpen && (
        <FloatingPortal>
          <div
            aria-label={surfaceMode === "actions" ? t("slug_reference.surface_label", { slug }) : undefined}
            className={floatingClassName}
            onMouseEnter={handleFloatingEnter}
            onMouseLeave={handleFloatingLeave}
            ref={refs.setFloating}
            role={surfaceMode === "actions" ? "dialog" : undefined}
            style={floatingStyle}
          >
            {surfaceMode === "actions" ? (
              <SlugReferenceActionSurface close={close} entry={entry} href={href} id={id} slug={slug} />
            ) : (
              <PreviewCard entry={entry} id={id} />
            )}
          </div>
        </FloatingPortal>
      )}
    </>
  )
}

function SlugReferenceActionSurface({ close, entry, href, id, slug }: { close: () => void; entry: SlugReferenceRegistryEntry; href: string | null; id: number; slug: string }) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()

  const copySlug = () => {
    copy(slug)
  }

  return (
    <div className="space-y-3 rounded-lg bg-surface text-text-primary">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="break-all font-mono text-sm font-semibold">{slug}</div>
          <div className="text-xs text-text-secondary">{entry.displayLabel}</div>
        </div>
        <button className={actionCloseButtonClassName} onClick={close} type="button">
          {t("slug_reference.close")}
        </button>
      </div>

      <div className="flex flex-wrap gap-2">
        {href ? <SlugReferenceOpenAction close={close} href={href} slug={slug} /> : null}
        {entry.copyable ? (
          <button
            className={actionButtonClassName}
            onClick={copySlug}
            type="button"
          >
            <CopyIcon className={`h-4 w-4 ${copied ? "text-success-text" : "text-text-secondary"}`} />
            {copied ? t("copy.copied") : t("slug_reference.copy_action", { slug })}
          </button>
        ) : null}
      </div>

      {entry.previewAvailable ? (
        <div className="max-h-[65vh] overflow-auto sm:max-h-[28rem]">
          <PreviewCard entry={entry} id={id} />
        </div>
      ) : (
        <p className="rounded border border-dashed border-border bg-surface-subtle px-3 py-2 text-sm text-text-secondary">{t("slug_reference.preview_unavailable")}</p>
      )}
    </div>
  )
}

function SlugReferenceOpenAction({ close, href, slug }: { close: () => void; href: string; slug: string }) {
  const { t } = useT("common")
  const label = t("slug_reference.open_action", { slug })

  if (href.startsWith("/s/")) {
    return (
      <a className={actionOpenClassName} href={href} onClick={close}>
        {label}
      </a>
    )
  }

  return (
    <Link className={actionOpenClassName} onClick={close} to={href}>
      {label}
    </Link>
  )
}

type LegacySlugHoverCardProps = {
  kind: "job" | "epic" | "plugin" | "chat"
  id: number
  prefix?: string
  children: ReactNode
}

const legacyEntries: Record<LegacySlugHoverCardProps["kind"], SlugReferenceRegistryEntry> = {
  chat: legacyEntry("CHAT", "chat", { hrefTemplate: "/chats/:id" }),
  epic: legacyEntry("EPIC", "epic", { hrefTemplate: "/epics/EPIC-:id" }),
  job: legacyEntry("JOB", "job", { hrefTemplate: "/jobs/JOB-:id" }),
  plugin: legacyEntry("PLUGIN", "plugin")
}

function legacyEntry(prefix: string, type: string, options: { hrefTemplate?: string | null; linkable?: boolean } = {}): SlugReferenceRegistryEntry {
  const hrefTemplate = options.hrefTemplate ?? null

  return {
    prefix,
    type,
    displayLabel: prefix,
    copyable: true,
    linkable: options.linkable ?? Boolean(hrefTemplate),
    previewAvailable: true,
    linkifiesGeneratedText: true,
    hrefTemplate,
    mobileInteractionHints: { tap: "open", long_press: "copy" },
    pluginPreviewComponent: null
  }
}

export function SlugHoverCard({ kind, prefix, id, children }: LegacySlugHoverCardProps) {
  const entry = prefix ? { ...legacyEntries.plugin, prefix, pluginPreviewComponent: pluginSlugPreviewCardComponentForPrefix(prefix) } : legacyEntries[kind]

  return (
    <SlugReferenceCard entry={entry} id={id}>
      {children}
    </SlugReferenceCard>
  )
}
