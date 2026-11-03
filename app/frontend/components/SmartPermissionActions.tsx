import { useEffect, useId, useRef, useState } from "react"
import { Link } from "react-router-dom"
import { ApiError } from "../api/client"
import type { SmartPermissionOption } from "../api/permissionRequests"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const BUTTON = "min-w-[7rem] flex-1 rounded-md px-3 py-1.5 text-sm font-semibold disabled:opacity-60 sm:flex-none motion-reduce:transition-none"

export const SMART_CUSTOMIZE_PATH = "/settings/permissions"

/**
 * The compact decision row shared by chat authorization cards and the approval
 * inbox: Allow once, an adaptive descriptor-driven action, and Deny. Choosing
 * the adaptive action opens an inline preview with Confirm, Back and Customize.
 * Both surfaces feed it the same `smart_option` payload.
 */
export function SmartPermissionActions({
  option,
  busy,
  error,
  onAllowOnce,
  onDeny,
  onConfirm,
  onStale,
  customizeTo = SMART_CUSTOMIZE_PATH
}: {
  option: SmartPermissionOption | null | undefined
  busy: boolean
  error: unknown
  onAllowOnce: () => void
  onDeny: () => void
  onConfirm: (option: SmartPermissionOption) => void
  onStale?: () => void
  customizeTo?: string
}) {
  const { t } = useT("settings")
  const headingId = useId()
  const headingRef = useRef<HTMLHeadingElement>(null)
  const adaptiveRef = useRef<HTMLButtonElement>(null)
  const [previewing, setPreviewing] = useState(false)
  const stale = error instanceof ApiError && error.status === 409
  const staleHandled = useRef(false)

  // A stale preview must never be confirmable: return to the actions and let
  // the parent reload the current request.
  useEffect(() => {
    if (stale && !staleHandled.current) {
      staleHandled.current = true
      setPreviewing(false)
      onStale?.()
    }
    if (!stale) staleHandled.current = false
  }, [stale, onStale])
  useEffect(() => {
    if (previewing) headingRef.current?.focus()
  }, [previewing])
  useEffect(() => {
    if (!option) setPreviewing(false)
  }, [option])

  const leavePreview = () => {
    setPreviewing(false)
    // Return focus to the control that opened the preview.
    requestAnimationFrame(() => adaptiveRef.current?.focus())
  }
  const failure = error ? (stale ? t("permission_smart.stale") : errorMessage(error, t("permission_smart.error"))) : null
  const label = option ? t(`permission_smart.${option.kind}`) : ""

  return (
    <div className="mt-3 space-y-2" data-testid="smart-permission-actions">
      {previewing && option ? (
        <section
          aria-busy={busy}
          aria-labelledby={headingId}
          className="space-y-2 rounded-lg border border-border bg-surface-subtle p-3 text-xs"
          onKeyDown={(event) => {
            if (event.key === "Escape" && !busy) {
              event.stopPropagation()
              leavePreview()
            }
          }}
          role="group"
        >
          <h3 className="text-sm font-semibold text-text-primary outline-none" id={headingId} ref={headingRef} tabIndex={-1}>
            {label}
          </h3>
          <dl className="grid gap-x-3 gap-y-1 sm:grid-cols-[auto_1fr]">
            <Row label={t("permission_smart.coworker")} value={option.context.coworker} />
            <Row label={t("permission_smart.operation")} value={option.context.operation} />
            <Row label={t("permission_smart.repository")} value={option.context.repository || t("permission_smart.no_repository")} />
            <Row label={t("permission_smart.scope")} value={option.context.resource_scope_label || t("permission_smart.any_scope")} />
            <Row label={t("permission_smart.duration")} value={t(`permission_smart.durations.${option.duration}`)} />
          </dl>
          <SummaryList items={option.summary.allows} title={t("permission_smart.allows")} />
          <SummaryList items={option.summary.excludes} title={t("permission_smart.excludes")} />
          <div className="flex flex-wrap items-center gap-2 pt-1">
            <button className={`${BUTTON} bg-brand text-on-brand`} disabled={busy} onClick={() => onConfirm(option)} type="button">
              {busy ? t("permission_smart.applying") : t("permission_smart.confirm")}
            </button>
            <button className="text-sm font-medium text-text-secondary underline-offset-2 hover:underline" disabled={busy} onClick={leavePreview} type="button">
              {t("permission_smart.back")}
            </button>
            <Link className="text-sm font-medium text-brand underline-offset-2 hover:underline" to={customizeTo}>
              {t("permission_smart.customize")}
            </Link>
          </div>
        </section>
      ) : (
        <div aria-label={t("permission_smart.group")} className="flex flex-wrap items-center gap-2" role="group">
          <button className={`${BUTTON} bg-brand text-on-brand`} disabled={busy} onClick={onAllowOnce} type="button">
            {t("permission_smart.allow_once")}
          </button>
          {option ? (
            <button className={`${BUTTON} border border-brand text-brand`} disabled={busy} onClick={() => setPreviewing(true)} ref={adaptiveRef} type="button">
              {label}
            </button>
          ) : null}
          <button className={`${BUTTON} border border-danger text-danger`} disabled={busy} onClick={onDeny} type="button">
            {t("permission_smart.deny")}
          </button>
        </div>
      )}
      <p aria-live="polite" className="sr-only" role="status">
        {previewing && option ? t("permission_smart.status_preview", { action: label }) : ""}
      </p>
      {failure ? (
        <p className="text-xs text-danger" role="alert">
          {failure}
        </p>
      ) : null}
    </div>
  )
}

function Row({ label, value }: { label: string; value: string | null }) {
  return (
    <>
      <dt className="font-medium text-text-muted">{label}</dt>
      <dd className="break-words text-text-secondary">{value || "—"}</dd>
    </>
  )
}

function SummaryList({ title, items }: { title: string; items: string[] }) {
  if (!items.length) return null
  return (
    <div>
      <p className="font-medium text-text-muted">{title}</p>
      <ul className="list-disc space-y-0.5 pl-4 text-text-secondary">
        {items.map((item) => (
          <li className="break-words" key={item}>
            {item}
          </li>
        ))}
      </ul>
    </div>
  )
}

/** Link from a decided item to the auditable, revocable rule it created. */
export function LinkedPermissionRule({ authority }: { authority?: { kind: string; id: number } | null }) {
  const { t } = useT("settings")
  if (authority?.kind !== "PermissionRule") return null
  return (
    <Link className="text-xs font-medium text-brand hover:underline" to={`${SMART_CUSTOMIZE_PATH}?rule=${authority.id}`}>
      {t("permission_smart.linked_rule", { id: authority.id })}
    </Link>
  )
}
