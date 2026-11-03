import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useId, useRef, useState, type FormEvent } from "react"
import { Link } from "react-router-dom"
import {
  applyRuleDraft,
  EMPTY_DRAFT,
  fetchRuleDraftOptions,
  fieldsFromPreview,
  previewRuleDraft,
  previewRuleDraftFromRequest,
  type DraftDuration,
  type DraftPolicy,
  type RuleDraftFields,
  type RuleDraftOptions,
  type RuleDraftPreview,
  type ScopeField
} from "../api/permissionRuleDrafts"
import { ApiError } from "../api/client"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Input } from "./Input"
import { PermissionRulePreview } from "./PermissionRulePreview"
import { Select } from "./Select"

export type RuleEditorSeed =
  | { kind: "request"; requestId: number; itemId: number; duration?: DraftDuration }
  | { kind: "fields"; fields: Partial<RuleDraftFields>; replaceRuleId?: number | null }
  | { kind: "blank"; capabilities: Array<{ capability: string; operation: string }> }

export const hubRuleLink = (requestId: number, itemId: number) => `/settings/permissions?request=${requestId}&item=${itemId}`

/**
 * The one fine-grained rule editor. It is a form over the canonical
 * draft / preview / apply contract: every field it offers comes from the
 * descriptor's options (subjects, durations, resource-scope fields, safe
 * constraints) and nothing is saved without a server preview and its digest.
 * Used from authorization cards, the Permissions Hub and confirmed
 * permission-management cards.
 */
export function PermissionRuleEditor({
  seed,
  onApplied,
  onCancel,
  headingLevel = 3
}: {
  seed: RuleEditorSeed
  onApplied: (result: { id: number; policy: DraftPolicy }) => void
  onCancel: () => void
  headingLevel?: 2 | 3
}) {
  const { t } = useT("settings")
  const ids = useId()
  const queryClient = useQueryClient()
  const headingRef = useRef<HTMLHeadingElement>(null)
  const [fields, setFields] = useState<RuleDraftFields>(() => (seed.kind === "fields" ? { ...EMPTY_DRAFT, ...seed.fields } : EMPTY_DRAFT))
  const [preview, setPreview] = useState<RuleDraftPreview | null>(null)
  const [previewedFields, setPreviewedFields] = useState<RuleDraftFields | null>(null)
  const [stale, setStale] = useState(false)
  const requestRef = seed.kind === "request" ? { requestId: seed.requestId, itemId: seed.itemId } : undefined
  const replaceRuleId = seed.kind === "fields" ? seed.replaceRuleId : null
  const Heading = `h${headingLevel}` as "h2" | "h3"

  const hydrate = useMutation({
    mutationFn: () =>
      previewRuleDraftFromRequest(
        seed.kind === "request" ? seed.requestId : 0,
        seed.kind === "request" ? seed.itemId : 0,
        seed.kind === "request" ? (seed.duration ?? "permanent") : "permanent"
      ),
    onSuccess: ({ preview: next }) => {
      setFields(fieldsFromPreview(next))
      setPreview(next)
      setPreviewedFields(fieldsFromPreview(next))
    }
  })
  const hydrateRef = useRef(hydrate.mutate)
  hydrateRef.current = hydrate.mutate
  useEffect(() => {
    if (seed.kind === "request") hydrateRef.current()
  }, [seed.kind === "request" ? seed.requestId : 0, seed.kind === "request" ? seed.itemId : 0])
  useEffect(() => headingRef.current?.focus(), [])

  const optionsQuery = useQuery({
    queryKey: ["permission_rule_options", fields.capability, fields.operation],
    queryFn: () => fetchRuleDraftOptions(fields.capability, fields.operation),
    enabled: Boolean(fields.capability && fields.operation)
  })
  const options = optionsQuery.data?.options

  const review = useMutation({
    mutationFn: () => previewRuleDraft(fields, requestRef),
    onSuccess: ({ preview: next }) => {
      setPreview(next)
      setPreviewedFields(fields)
      setStale(false)
    },
    onError: (error) => {
      // Invalid drafts answer 422 with their issues; show them as the preview.
      if (error instanceof ApiError && error.status === 422 && Array.isArray(error.issues)) {
        setPreview({
          valid: false,
          errors: error.issues as RuleDraftPreview["errors"],
          warnings: [],
          digest: null,
          draft: null,
          summary: null,
          ceiling: null,
          examples: null
        })
        setPreviewedFields(fields)
      }
    }
  })
  const apply = useMutation({
    mutationFn: () => applyRuleDraft(fields, preview!.digest!, { replaceRuleId }),
    onSuccess: ({ authority }) => {
      // A new or replaced rule changes the Hub's rules, leases and audit history.
      void queryClient.invalidateQueries({ queryKey: ["permission_rules"] })
      void queryClient.invalidateQueries({ queryKey: ["permission_history"] })
      onApplied({ id: authority.id, policy: fields.policy })
    },
    onError: (error) => {
      if (error instanceof ApiError && error.status === 409) {
        setStale(true)
        setPreview(null)
      }
    }
  })

  const update = (patch: Partial<RuleDraftFields>) => setFields((current) => ({ ...current, ...patch }))
  const current = preview && previewedFields && JSON.stringify(previewedFields) === JSON.stringify(fields)
  const savable = Boolean(current && preview?.valid && preview.digest)
  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (savable) apply.mutate()
    else review.mutate()
  }
  const blankSeed = seed.kind === "blank" ? seed : null
  const loading = hydrate.isPending || (seed.kind === "request" && !preview && !hydrate.isError)
  const failure = hydrate.error ?? apply.error ?? (review.error instanceof ApiError && review.error.status === 422 ? null : review.error)

  return (
    <form
      aria-busy={loading || review.isPending || apply.isPending}
      aria-labelledby={`${ids}-title`}
      className="space-y-4 text-sm"
      data-testid="permission-rule-editor"
      onKeyDown={(event) => {
        if (event.key === "Escape" && !apply.isPending) {
          event.stopPropagation()
          onCancel()
        }
      }}
      onSubmit={submit}
    >
      <Heading className="text-base font-semibold text-text-primary outline-none" id={`${ids}-title`} ref={headingRef} tabIndex={-1}>
        {t(replaceRuleId ? "permission_editor.title_edit" : "permission_editor.title")}
      </Heading>
      {loading ? <p role="status">{t("permission_editor.loading")}</p> : null}
      <div className="grid gap-3 sm:grid-cols-2">
        {blankSeed ? (
          <Field label={t("permission_editor.capability")} htmlFor={`${ids}-cap`}>
            <Select
              id={`${ids}-cap`}
              onChange={(event) => {
                const [capability, operation] = event.target.value.split("|")
                update({ capability, operation, subject_selector_type: "", resource_scope: {}, constraints: {} })
                setPreview(null)
              }}
              value={fields.capability ? `${fields.capability}|${fields.operation}` : ""}
            >
              <option value="">{t("permission_editor.choose_capability")}</option>
              {blankSeed.capabilities.map((item) => (
                <option key={`${item.capability}|${item.operation}`} value={`${item.capability}|${item.operation}`}>
                  {item.capability} · {item.operation}
                </option>
              ))}
            </Select>
          </Field>
        ) : (
          <div>
            <p className="font-medium">{t("permission_editor.capability")}</p>
            <p className="mt-1 break-words text-text-secondary">
              {fields.capability} · {fields.operation}
            </p>
          </div>
        )}
        {options ? (
          <>
            <SubjectFields fields={fields} idBase={ids} onChange={update} options={options} />
            <Field label={t("permission_editor.policy")} htmlFor={`${ids}-policy`}>
              <Select
                id={`${ids}-policy`}
                onChange={(event) => {
                  const policy = event.target.value as DraftPolicy
                  update({ policy, ...(policy !== "allow" ? { duration: "permanent", constraints: {} } : {}) })
                }}
                value={fields.policy}
              >
                {options.policies.map((policy) => (
                  <option key={policy} value={policy}>
                    {t(`permission_editor.policies.${policy}`)}
                  </option>
                ))}
              </Select>
            </Field>
            <DurationField fields={fields} idBase={ids} onChange={update} options={options} />
            <ScopeFields fields={fields} idBase={ids} onChange={update} options={options} preview={preview} />
            <ConstraintFields fields={fields} idBase={ids} onChange={update} options={options} />
          </>
        ) : null}
        <Field label={t("permission_editor.rationale")} htmlFor={`${ids}-rationale`} wide>
          <Input id={`${ids}-rationale`} maxLength={1000} onChange={(event) => update({ rationale: event.target.value })} value={fields.rationale} />
        </Field>
      </div>
      {options?.ceilings.length ? (
        <p className="text-xs text-text-muted">{t("permission_editor.ceilings_present", { count: options.ceilings.length })}</p>
      ) : null}
      {preview ? (
        <div className={current ? "" : "opacity-60"} data-testid="permission-editor-preview">
          <PermissionRulePreview headingLevel={3} preview={preview} />
          {!current ? <p className="mt-1 text-xs text-text-muted">{t("permission_editor.preview_outdated")}</p> : null}
        </div>
      ) : null}
      {stale ? (
        <p className="text-xs text-danger" role="alert">
          {t("permission_editor.stale")}
        </p>
      ) : null}
      {failure ? (
        <p className="text-xs text-danger" role="alert">
          {errorMessage(failure, t("permission_editor.error"))}
        </p>
      ) : null}
      <div className="flex flex-wrap items-center gap-2">
        <button
          className="min-h-9 rounded-md bg-brand px-4 py-2 text-sm font-semibold text-on-brand disabled:opacity-50"
          disabled={loading || review.isPending || apply.isPending || !fields.capability}
          type="submit"
        >
          {apply.isPending
            ? t("permission_editor.saving")
            : savable
              ? t("permission_editor.save")
              : review.isPending
                ? t("permission_editor.reviewing")
                : t("permission_editor.review")}
        </button>
        <button className="min-h-9 rounded-md border border-border px-4 py-2 text-sm" disabled={apply.isPending} onClick={onCancel} type="button">
          {t("permission_editor.cancel")}
        </button>
        {requestRef ? (
          <Link className="text-sm font-medium text-brand underline-offset-2 hover:underline" to={hubRuleLink(requestRef.requestId, requestRef.itemId)}>
            {t("permission_editor.open_in_hub")}
          </Link>
        ) : null}
      </div>
    </form>
  )
}

function Field({ label, htmlFor, wide, children }: { label: string; htmlFor: string; wide?: boolean; children: React.ReactNode }) {
  return (
    <div className={wide ? "sm:col-span-2" : ""}>
      <label className="block font-medium" htmlFor={htmlFor}>
        {label}
      </label>
      <div className="mt-1">{children}</div>
    </div>
  )
}

type SectionProps = { fields: RuleDraftFields; idBase: string; onChange: (patch: Partial<RuleDraftFields>) => void; options: RuleDraftOptions }

function SubjectFields({ fields, idBase, onChange, options }: SectionProps) {
  const { t } = useT("settings")
  const subject = options.subject_types.find((item) => item.type === fields.subject_selector_type)
  return (
    <>
      <Field label={t("permission_editor.subject")} htmlFor={`${idBase}-subject`}>
        <Select
          id={`${idBase}-subject`}
          onChange={(event) => {
            const next = options.subject_types.find((item) => item.type === event.target.value)
            onChange({
              subject_selector_type: event.target.value,
              subject_selector_id: "",
              subject_type: next?.exact_agent ? fields.subject_type : "",
              subject_repository_id: "",
              role: next?.roles.length === 1 ? next.roles[0] : fields.role
            })
          }}
          value={fields.subject_selector_type}
        >
          <option value="">{t("permission_editor.choose_subject")}</option>
          {options.subject_types.map((item) => (
            <option key={item.type} value={item.type}>
              {t(`permission_editor.subject_types.${item.type}`, { defaultValue: item.type })}
            </option>
          ))}
        </Select>
      </Field>
      {subject?.requires_id ? (
        <Field label={t(subject.exact_agent ? "permission_editor.coworker_id" : "permission_editor.subject_id")} htmlFor={`${idBase}-subject-id`}>
          {subject.roles.length > 1 && !subject.exact_agent ? (
            <Select id={`${idBase}-subject-id`} onChange={(event) => onChange({ subject_selector_id: event.target.value })} value={fields.subject_selector_id}>
              <option value="">{t("permission_editor.choose_role")}</option>
              {subject.roles.map((role) => (
                <option key={role} value={role}>
                  {role}
                </option>
              ))}
            </Select>
          ) : (
            <Input id={`${idBase}-subject-id`} onChange={(event) => onChange({ subject_selector_id: event.target.value })} value={fields.subject_selector_id} />
          )}
        </Field>
      ) : null}
      {subject?.exact_agent && subject.roles.length > 1 ? (
        <Field label={t("permission_editor.role")} htmlFor={`${idBase}-role`}>
          <Select id={`${idBase}-role`} onChange={(event) => onChange({ role: event.target.value })} value={fields.role}>
            <option value="">{t("permission_editor.choose_role")}</option>
            {subject.roles.map((role) => (
              <option key={role} value={role}>
                {role}
              </option>
            ))}
          </Select>
        </Field>
      ) : null}
      {subject?.requires_repository ? (
        <Field label={t("permission_editor.repository_id")} htmlFor={`${idBase}-repo`}>
          <Input
            id={`${idBase}-repo`}
            inputMode="numeric"
            onChange={(event) => onChange({ subject_repository_id: event.target.value })}
            value={fields.subject_repository_id}
          />
        </Field>
      ) : null}
    </>
  )
}

function DurationField({ fields, idBase, onChange, options }: SectionProps) {
  const { t } = useT("settings")
  // Standing ask/deny rules are permanent; chat/job leases need the lifecycle
  // record the draft was seeded with, so they are only offered when present.
  const offered =
    fields.policy !== "allow"
      ? (["permanent"] as DraftDuration[])
      : options.authority_durations.filter((duration) => {
          if (duration === "chat_session") return Boolean(fields.chat_session_id)
          if (duration === "job") return Boolean(fields.job_id)
          return true
        })
  const durations = offered.includes(fields.duration) ? offered : [...offered, fields.duration]
  return (
    <Field label={t("permission_editor.duration")} htmlFor={`${idBase}-duration`}>
      <Select
        id={`${idBase}-duration`}
        onChange={(event) => onChange({ duration: event.target.value as DraftDuration, ...(event.target.value === "permanent" ? { constraints: {} } : {}) })}
        value={fields.duration}
      >
        {durations.map((duration) => (
          <option key={duration} value={duration}>
            {t(`permission_smart.durations.${duration}`)}
          </option>
        ))}
      </Select>
    </Field>
  )
}

function ScopeFields({ fields, idBase, onChange, options, preview }: SectionProps & { preview: RuleDraftPreview | null }) {
  const { t } = useT("settings")
  const schemaFields: ScopeField[] = options.resource_scope.options?.fields ?? []
  if (schemaFields.length === 0) {
    const label = preview?.draft?.resource_scope_label
    return Object.keys(fields.resource_scope).length > 0 ? (
      <div className="sm:col-span-2">
        <p className="font-medium">{t("permission_editor.resource_scope")}</p>
        <p className="mt-1 break-words text-text-secondary">{label || t("permission_editor.scope_fixed")}</p>
      </div>
    ) : null
  }
  const setScope = (name: string, value: unknown) => {
    const next = { ...fields.resource_scope }
    if (value === "" || value == null) delete next[name]
    else next[name] = value
    onChange({ resource_scope: next })
  }
  return (
    <>
      {schemaFields.map((field) => {
        const id = `${idBase}-scope-${field.name}`
        const value = fields.resource_scope[field.name]
        return (
          <Field key={field.name} label={field.label} htmlFor={id}>
            {field.type === "select" ? (
              <Select id={id} onChange={(event) => setScope(field.name, event.target.value)} value={String(value ?? "")}>
                <option value="">{t("permission_editor.any")}</option>
                {field.choices?.map((choice) => (
                  <option key={choice.value} value={choice.value}>
                    {choice.label}
                  </option>
                ))}
              </Select>
            ) : (
              <ScalarInput id={id} onValue={(next) => setScope(field.name, next)} type={field.type} value={value} />
            )}
          </Field>
        )
      })}
    </>
  )
}

function ConstraintFields({ fields, idBase, onChange, options }: SectionProps) {
  const { t } = useT("settings")
  // The evaluator only enforces constraints on bounded allow authority.
  const entries = Object.entries(options.constraint_fields)
  if (fields.policy !== "allow" || fields.duration === "permanent" || entries.length === 0) return null
  const setConstraint = (name: string, value: unknown) => {
    const next = { ...fields.constraints }
    if (value === "" || value == null) delete next[name]
    else next[name] = value
    onChange({ constraints: next })
  }
  return (
    <fieldset className="sm:col-span-2">
      <legend className="font-medium">{t("permission_editor.constraints")}</legend>
      <div className="mt-1 grid gap-3 sm:grid-cols-2">
        {entries.map(([name, type]) => {
          const id = `${idBase}-constraint-${name}`
          return (
            <Field key={name} label={name} htmlFor={id}>
              <ScalarInput id={id} onValue={(next) => setConstraint(name, next)} type={type} value={fields.constraints[name]} />
            </Field>
          )
        })}
      </div>
    </fieldset>
  )
}

function ScalarInput({
  id,
  type,
  value,
  onValue
}: {
  id: string
  type: "string" | "integer" | "boolean" | ScopeField["type"]
  value: unknown
  onValue: (value: unknown) => void
}) {
  const { t } = useT("settings")
  if (type === "boolean") {
    return (
      <Select
        id={id}
        onChange={(event) => onValue(event.target.value === "" ? "" : event.target.value === "true")}
        value={value === undefined ? "" : String(value)}
      >
        <option value="">{t("permission_editor.any")}</option>
        <option value="true">{t("permission_editor.yes")}</option>
        <option value="false">{t("permission_editor.no")}</option>
      </Select>
    )
  }
  return (
    <Input
      id={id}
      inputMode={type === "integer" ? "numeric" : undefined}
      onChange={(event) => {
        const raw = event.target.value
        onValue(type === "integer" && raw !== "" && /^-?\d+$/.test(raw) ? Number(raw) : raw)
      }}
      value={value === undefined ? "" : String(value)}
    />
  )
}
