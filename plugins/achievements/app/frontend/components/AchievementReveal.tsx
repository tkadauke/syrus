import { useEffect, useId, useRef, useState } from "react"
import { Button } from "@app/components/Button"
import { Modal } from "@app/components/Modal"
import { Text } from "@app/components/ui"
import { reportHandledError } from "@app/lib/handledErrorReporting"
import { useT } from "@app/hooks/useT"
import type { AchievementUnlock } from "../api/achievements"

export type AckStatus = "idle" | "saving" | "done" | "failed"

// Deterministic presentation order: oldest unlock first, id as the tie-break.
export function sortReveals(reveals: AchievementUnlock[]): AchievementUnlock[] {
  return [...reveals].sort((a, b) => a.unlocked_at.localeCompare(b.unlocked_at) || a.id - b.id)
}

export function useDocumentVisible() {
  const [visible, setVisible] = useState(() => typeof document === "undefined" || document.visibilityState !== "hidden")
  useEffect(() => {
    const update = () => setVisible(document.visibilityState !== "hidden")
    document.addEventListener("visibilitychange", update)
    return () => document.removeEventListener("visibilitychange", update)
  }, [])
  return visible
}

export function usePrefersReducedMotion() {
  const query = "(prefers-reduced-motion: reduce)"
  const [reduced, setReduced] = useState(() => typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia(query).matches)
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return
    const media = window.matchMedia(query)
    const update = () => setReduced(media.matches)
    media.addEventListener?.("change", update)
    return () => media.removeEventListener?.("change", update)
  }, [])
  return reduced
}

type Props = {
  unlock: AchievementUnlock
  position: number
  total: number
  ackStatus: AckStatus
  onPresented: (unlock: AchievementUnlock) => void
  onRetry: (unlock: AchievementUnlock) => void
  onContinue: (unlock: AchievementUnlock) => void
}

// One reveal, as a modal dialog. Neutral placeholder art (a plain ring) stands in
// for the final badge. It never plays sound. The reveal counts as "presented"
// once it is mounted while the tab is visible -- only then is `onPresented`
// called, so the caller acknowledges what the user could actually see.
export function AchievementReveal({ unlock, position, total, ackStatus, onPresented, onRetry, onContinue }: Props) {
  const { t } = useT("achievements")
  const titleId = useId()
  const descriptionId = useId()
  const visible = useDocumentVisible()
  const reducedMotion = usePrefersReducedMotion()
  const [entered, setEntered] = useState(reducedMotion)
  const continueRef = useRef<HTMLButtonElement>(null)
  const presentedRef = useRef<number | null>(null)

  useEffect(() => {
    if (reducedMotion) return setEntered(true)
    const frame = requestAnimationFrame(() => setEntered(true))
    return () => cancelAnimationFrame(frame)
  }, [reducedMotion, unlock.id])

  useEffect(() => {
    if (!visible || presentedRef.current === unlock.id) return
    presentedRef.current = unlock.id
    onPresented(unlock)
  }, [visible, unlock, onPresented])

  const title = unlock.presentation.title_key ? t(unlock.presentation.title_key) : unlock.key
  const description = unlock.presentation.description_key ? t(unlock.presentation.description_key) : null
  const motionClasses = reducedMotion ? "" : "transition duration-500 ease-out"
  const stateClasses = entered ? "scale-100 opacity-100" : reducedMotion ? "" : "scale-95 opacity-0"

  return (
    <Modal
      open
      onClose={() => onContinue(unlock)}
      labelledBy={titleId}
      initialFocusRef={continueRef}
      className={`w-full max-w-md rounded-[var(--radius-panel)] bg-surface p-6 text-center shadow-[var(--shadow-panel)] ${motionClasses} ${stateClasses}`}
    >
      <div data-testid="achievement-reveal" data-reduced-motion={reducedMotion ? "true" : "false"}>
        <div aria-hidden="true" className="mx-auto mb-4 flex h-20 w-20 items-center justify-center rounded-full border-4 border-border bg-surface-raised">
          <span className="h-8 w-8 rounded-full border-2 border-brand" />
        </div>
        <Text as="p" tone="muted" variant="caption" className="uppercase">
          {t(unlock.scope === "instance" ? "reveal_instance" : "reveal_user")}
        </Text>
        <h2 className="mt-1 text-lg font-semibold text-text-primary" id={titleId}>
          {title}
        </h2>
        {description ? (
          <p className="mt-2 text-sm text-text-secondary" id={descriptionId}>
            {description}
          </p>
        ) : null}
        <div aria-live="polite" className="mt-3 min-h-5 text-xs text-text-secondary" role="status">
          {total > 1 ? <span>{t("reveal_position", { position, total })}</span> : null}
        </div>
        {ackStatus === "failed" ? (
          <div className="mt-2 flex items-center justify-center gap-2 text-xs text-danger" role="alert">
            <span>{t("reveal_ack_failed")}</span>
            <Button onClick={() => onRetry(unlock)} size="sm" variant="secondary">
              {t("reveal_retry")}
            </Button>
          </div>
        ) : null}
        <div className="mt-4">
          <Button onClick={() => onContinue(unlock)} ref={continueRef} variant="primary">
            {position < total ? t("reveal_next") : t("reveal_continue")}
          </Button>
        </div>
      </div>
    </Modal>
  )
}

type QueueProps = {
  reveals: AchievementUnlock[]
  acknowledge: (unlock: AchievementUnlock) => Promise<unknown>
  onFinished?: () => void
}

// Presents `reveals` one at a time in a stable order. A reveal is acknowledged
// only after it has been presented; a failed acknowledgment can be retried and
// never traps the user -- the reveal simply stays pending server-side and
// returns next time. Unmounting before presentation acknowledges nothing.
export function AchievementRevealQueue({ reveals, acknowledge, onFinished }: QueueProps) {
  const [dismissed, setDismissed] = useState<Set<number>>(new Set())
  const [status, setStatus] = useState<Record<number, AckStatus>>({})
  const statusRef = useRef<Record<number, AckStatus>>({})
  const acknowledgeRef = useRef(acknowledge)
  acknowledgeRef.current = acknowledge
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])

  function setAck(id: number, value: AckStatus) {
    statusRef.current = { ...statusRef.current, [id]: value }
    if (mounted.current) setStatus(statusRef.current)
  }

  const [ordered, setOrdered] = useState<AchievementUnlock[]>([])
  useEffect(() => {
    setOrdered((current) => {
      const known = new Set(current.map((unlock) => unlock.id))
      const additions = sortReveals(reveals.filter((unlock) => !known.has(unlock.id)))
      return additions.length === 0 ? current : [...current, ...additions]
    })
  }, [reveals])

  const queue = ordered.filter((unlock) => !dismissed.has(unlock.id))
  const current = queue[0]

  const finishedRef = useRef(false)
  useEffect(() => {
    if (ordered.length > 0 && !current && !finishedRef.current) {
      finishedRef.current = true
      onFinished?.()
    }
    if (current) finishedRef.current = false
  }, [ordered.length, current, onFinished])

  async function ack(unlock: AchievementUnlock) {
    const existing = statusRef.current[unlock.id]
    if (existing === "saving" || existing === "done") return
    setAck(unlock.id, "saving")
    try {
      await acknowledgeRef.current(unlock)
      setAck(unlock.id, "done")
    } catch (error) {
      reportHandledError(error, { surface: "achievements", operation: "acknowledge_reveal", stage: "acknowledge", recoverability: "retryable" })
      setAck(unlock.id, "failed")
    }
  }

  if (!current) return null

  const total = ordered.length
  return (
    <AchievementReveal
      ackStatus={status[current.id] ?? "idle"}
      key={current.id}
      onContinue={(unlock) => setDismissed((previous) => new Set(previous).add(unlock.id))}
      onPresented={ack}
      onRetry={ack}
      position={ordered.indexOf(current) + 1}
      total={total}
      unlock={current}
    />
  )
}
