import { FloatingPortal, autoPlacement, flip, offset, shift, useFloating } from "@floating-ui/react"
import { type ComponentType, type MouseEvent, type ReactNode, Suspense, useCallback, useEffect, useRef, useState } from "react"
import { pluginSlugPreviewCardComponentForPrefix, type PluginSlugPreviewCardProps } from "../pluginSlugPreviewCards"
import type { SlugReferenceRegistryEntry } from "../lib/slugReferenceRegistry"
import { ChatPreviewCard } from "./ChatPreviewCard"
import { EpicPreviewCard } from "./EpicPreviewCard"
import { JobPreviewCard } from "./JobPreviewCard"

const corePreviewCards: Record<string, ComponentType<{ id: number; compact?: boolean }>> = {
  chat: ChatPreviewCard,
  epic: EpicPreviewCard,
  job: JobPreviewCard
}

interface SlugReferenceCardProps {
  entry: SlugReferenceRegistryEntry
  id: number
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
  return typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia("(hover: hover) and (pointer: fine)").matches
}

export function SlugReferenceCard({ entry, id, children }: SlugReferenceCardProps) {
  const [isOpen, setIsOpen] = useState(false)
  const openTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  // Checked once on first render; pointer capability doesn't change during a session
  const canHover = useRef(detectPointerFine())

  const { refs, floatingStyles } = useFloating({
    middleware: [offset(8), flip({ padding: 8 }), autoPlacement({ padding: 8 }), shift({ padding: 8 })]
  })

  const open = useCallback(() => {
    if (!entry.previewAvailable) return
    setIsOpen(true)
  }, [entry.previewAvailable])

  const close = useCallback(() => {
    setIsOpen(false)
  }, [])

  const handleReferenceEnter = useCallback(() => {
    if (!entry.previewAvailable) return
    if (!canHover.current) return
    if (closeTimer.current) clearTimeout(closeTimer.current)
    openTimer.current = setTimeout(() => setIsOpen(true), 300)
  }, [entry.previewAvailable])

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
      if (canHover.current || !entry.previewAvailable) return
      if ((event.target as HTMLElement).closest("[data-slug-copy-button]")) return

      event.preventDefault()
      open()
    },
    [entry.previewAvailable, open]
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

  return (
    <>
      <span
        onClick={handleClick}
        onFocus={open}
        onMouseEnter={handleReferenceEnter}
        onMouseLeave={handleReferenceLeave}
        ref={refs.setReference}
        style={{ display: "inline" }}
      >
        {children}
      </span>
      {isOpen && (
        <FloatingPortal>
          <div
            className="[&>*]:max-w-[calc(100vw-1rem)]"
            onMouseEnter={handleFloatingEnter}
            onMouseLeave={handleFloatingLeave}
            ref={refs.setFloating}
            style={{ ...floatingStyles, zIndex: 50 }}
          >
            <PreviewCard entry={entry} id={id} />
          </div>
        </FloatingPortal>
      )}
    </>
  )
}

type LegacySlugHoverCardProps = {
  kind: "job" | "epic" | "plugin" | "chat"
  id: number
  prefix?: string
  children: ReactNode
}

const legacyEntries: Record<LegacySlugHoverCardProps["kind"], SlugReferenceRegistryEntry> = {
  chat: legacyEntry("CHAT", "chat", false),
  epic: legacyEntry("EPIC", "epic"),
  job: legacyEntry("JOB", "job"),
  plugin: legacyEntry("PLUGIN", "plugin")
}

function legacyEntry(prefix: string, type: string, linkable = true): SlugReferenceRegistryEntry {
  return {
    prefix,
    type,
    displayLabel: prefix,
    copyable: true,
    linkable,
    previewAvailable: true,
    linkifiesGeneratedText: true,
    hrefTemplate: null,
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
