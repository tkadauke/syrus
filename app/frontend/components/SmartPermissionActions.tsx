import { useEffect, useId, useRef, useState } from "react"
import { Link } from "react-router-dom"
import { ApiError } from "../api/client"
import type { SmartPermissionOption } from "../api/permissionRequests"
import { previewRuleDraftFromRequest } from "../api/permissionRuleDrafts"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Input } from "./Input"
import { Modal } from "./Modal"
import { hubRuleLink, PermissionRuleEditor } from "./PermissionRuleEditor"

const BUTTON = "min-w-[7rem] flex-1 rounded-md px-3 py-1.5 text-sm font-semibold disabled:opacity-60 sm:flex-none motion-reduce:transition-none"

const EDITOR_PANEL = "max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-[var(--radius-panel)] bg-surface p-4 shadow-[var(--shadow-panel)] sm:p-5"

export const SMART_CUSTOMIZE_PATH = "/settings/permissions"

/**
 * The compact decision row shared by chat authorization cards and the approval
 * inbox: Allow once, each descriptor-driven scoped action, and Deny. Choosing
 * a scoped action opens an inline preview with Confirm, Back and Customize.
 */
export function SmartPermissionActions({
  option,
  options,
  busy,
  error,
  onAllowOnce,
  onDeny,
  onConfirm,
  onStale,
  customizeTo = SMART_CUSTOMIZE_PATH,
  request,
  onCustomized
}: {
  option: SmartPermissionOption | null | undefined
  options?: SmartPermissionOption[]
  busy: boolean
  error: unknown
  onAllowOnce: () => void
  onDeny: () => void
  onConfirm: (option: SmartPermissionOption) => void
  onStale?: () => void
  customizeTo?: string
  /** The exact pending call; enables the in-card fine-grained rule editor. */
  request?: { requestId: number; itemId: number }
  /** Called after a customized rule is saved, with the decision it implies for this call. */
  onCustomized?: (decision: "approved" | "denied") => void
}) {
  const { t } = useT("settings")
  const headingId = useId()
  const headingRef = useRef<HTMLHeadingElement>(null)
  const adaptiveRefs = useRef<Record<string, HTMLButtonElement | null>>({})
  const [selectedOption, setSelectedOption] = useState<SmartPermissionOption | null>(null)
  const [previewing, setPreviewing] = useState(false)
  const [customizing, setCustomizing] = useState(false)
  // The prefix an operator is editing, and whatever went wrong re-previewing it.
  const [prefix, setPrefix] = useState<string | null>(null)
  const [prefixError, setPrefixError] = useState<string | null>(null)
  const [resolvingPrefix, setResolvingPrefix] = useState(false)
  const prefixId = useId()
  const customizeRef = useRef<HTMLButtonElement>(null)
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
    setPrefixError(null)
    setPrefix(previewing ? (selectedOption?.prefix?.value ?? null) : null)
  }, [previewing, selectedOption])
  useEffect(() => {
    if (!(options?.length || option)) setPreviewing(false)
  }, [option, options])

  const leavePreview = () => {
    setPreviewing(false)
    // Return focus to the control that opened the preview.
    const duration = selectedOption?.duration
    requestAnimationFrame(() => duration && adaptiveRefs.current[duration]?.focus())
  }
  // Confirming an edited prefix writes a different rule than the one previewed,
  // so its digest is fetched for that exact prefix rather than reused. Leaving
  // the suggestion untouched keeps the digest already in hand.
  const confirm = async (candidate: SmartPermissionOption) => {
    const edited = prefix?.trim()
    if (!candidate.prefix || !edited || edited === candidate.prefix.value) {
      onConfirm(candidate.prefix && edited ? { ...candidate, prefix: { ...candidate.prefix, value: edited } } : candidate)
      return
    }
    if (!request) return
    setPrefixError(null)
    setResolvingPrefix(true)
    try {
      const { preview } = await previewRuleDraftFromRequest(request.requestId, request.itemId, candidate.duration, "allow", edited)
      if (!preview.valid || !preview.digest) {
        setPrefixError(preview.errors?.[0]?.message || t("permission_smart.prefix_invalid"))
        return
      }
      onConfirm({ ...candidate, digest: preview.digest, prefix: { ...candidate.prefix, value: edited } })
    } catch (caught) {
      setPrefixError(errorMessage(caught, t("permission_smart.prefix_invalid")))
    } finally {
      setResolvingPrefix(false)
    }
  }

  const failure = error ? (stale ? t("permission_smart.stale") : errorMessage(error, t("permission_smart.error"))) : null
  const availableOptions = options?.length ? options : option ? [option] : []
  const activeOption = selectedOption || availableOptions[0] || null
  const label = activeOption ? t(`permission_smart.${activeOption.kind}`) : ""

  return (
    <div className="mt-3 space-y-2" data-testid="smart-permission-actions">
      {previewing && activeOption ? (
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
            <Row label={t("permission_smart.coworker")} value={activeOption.context.coworker} />
            <Row label={t("permission_smart.operation")} value={activeOption.context.operation} />
            <Row label={t("permission_smart.repository")} value={activeOption.context.repository || t("permission_smart.no_repository")} />
            <Row label={t("permission_smart.scope")} value={activeOption.context.resource_scope_label || t("permission_smart.any_scope")} />
            <Row label={t("permission_smart.duration")} value={t(`permission_smart.durations.${activeOption.duration}`)} />
          </dl>
          <SummaryList items={activeOption.summary.allows} title={t("permission_smart.allows")} />
          <SummaryList items={activeOption.summary.excludes} title={t("permission_smart.excludes")} />
          {activeOption.prefix && request ? (
            <div className="space-y-1 pt-1" data-testid="smart-permission-prefix">
              <label className="block text-xs font-semibold text-text-primary" htmlFor={prefixId}>
                {t("permission_smart.prefix_label")}
              </label>
              <Input
                className="font-mono text-xs"
                disabled={busy || resolvingPrefix}
                id={prefixId}
                onChange={(event) => {
                  setPrefix(event.target.value)
                  setPrefixError(null)
                }}
                spellCheck={false}
                value={prefix ?? ""}
              />
              <p className="text-xs text-text-secondary">
                {t("permission_smart.prefix_hint", { command: activeOption.prefix.full })}
              </p>
              {prefixError ? (
                <p className="text-xs text-danger" role="alert">
                  {prefixError}
                </p>
              ) : null}
            </div>
          ) : null}
          <div className="flex flex-wrap items-center gap-2 pt-1">
            <button
              className={`${BUTTON} bg-brand text-on-brand`}
              disabled={busy || resolvingPrefix || (!!activeOption.prefix && !prefix?.trim())}
              onClick={() => void confirm(activeOption)}
              type="button"
            >
              {busy || resolvingPrefix ? t("permission_smart.applying") : t("permission_smart.confirm")}
            </button>
            <button className="text-sm font-medium text-text-secondary underline-offset-2 hover:underline" disabled={busy} onClick={leavePreview} type="button">
              {t("permission_smart.back")}
            </button>
            {request ? (
              <button
                className="text-sm font-medium text-brand underline-offset-2 hover:underline"
                disabled={busy}
                onClick={() => setCustomizing(true)}
                ref={customizeRef}
                type="button"
              >
                {t("permission_smart.customize")}
              </button>
            ) : (
              <Link className="text-sm font-medium text-brand underline-offset-2 hover:underline" to={customizeTo}>
                {t("permission_smart.customize")}
              </Link>
            )}
          </div>
        </section>
      ) : (
        <div aria-label={t("permission_smart.group")} className="flex flex-wrap items-center gap-2" role="group">
          <button className={`${BUTTON} bg-brand text-on-brand`} disabled={busy} onClick={onAllowOnce} type="button">
            {t("permission_smart.allow_once")}
          </button>
          {availableOptions.map((candidate) => (
            <button
              className={`${BUTTON} border border-brand text-brand`}
              disabled={busy}
              key={candidate.duration}
              onClick={() => {
                setSelectedOption(candidate)
                setPreviewing(true)
              }}
              ref={(element) => {
                adaptiveRefs.current[candidate.duration] = element
              }}
              type="button"
            >
              {t(`permission_smart.${candidate.kind}`)}
            </button>
          ))}
          <button className={`${BUTTON} border border-danger text-danger`} disabled={busy} onClick={onDeny} type="button">
            {t("permission_smart.deny")}
          </button>
        </div>
      )}
      {request ? (
        <Modal className={EDITOR_PANEL} label={t("permission_editor.title")} onClose={() => setCustomizing(false)} open={customizing}>
          <PermissionRuleEditor
            onApplied={({ policy }) => {
              setCustomizing(false)
              // The saved rule is standing policy; this pending call still needs its own decision.
              onCustomized?.(policy === "deny" ? "denied" : "approved")
            }}
            onCancel={() => {
              setCustomizing(false)
              requestAnimationFrame(() => customizeRef.current?.focus())
            }}
            seed={{ kind: "request", requestId: request.requestId, itemId: request.itemId, duration: activeOption?.duration }}
          />
        </Modal>
      ) : null}
      <p aria-live="polite" className="sr-only" role="status">
        {previewing && activeOption ? t("permission_smart.status_preview", { action: label }) : ""}
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
