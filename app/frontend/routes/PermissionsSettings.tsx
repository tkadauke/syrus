import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { TFunction } from "i18next"
import { useEffect, useMemo, useState } from "react"
import { Link, useLocation, useSearchParams } from "react-router-dom"
import {
  applyPermissionBulk,
  applyPermissionProfile,
  applyPermissionPreset,
  fetchPermissionHistory,
  fetchPermissions,
  previewPermissionBulk,
  previewPermissionProfile,
  revokePermissionRule,
  type InheritedPermission,
  type PermissionBulkOperation,
  type PermissionHistoryEntry,
  type PermissionLease,
  type PermissionPreview,
  type PermissionRule
} from "../api/permissions"
import { AiApprovalDelegations } from "./AiApprovalDelegations"
import { PermissionRuleEditor, type RuleEditorSeed } from "../components/PermissionRuleEditor"
import { Modal } from "../components/Modal"
import { PageHeading, SectionHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { Select } from "../components/Select"
import { Checkbox, DataTable } from "../components/ui"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"
import { routePrefix, withRoutePrefix } from "../lib/routing"

const queryKey = ["permission_rules"] as const
const subjects = ["interactive_chat", "coding_chat", "local_chat"] as const
type Subject = (typeof subjects)[number]
type View = "matrix" | "resources" | "rules" | "leases" | "history" | "ai_approval"
type PolicyState = "allow" | "ask" | "deny" | "scoped"
type Translate = TFunction<"settings">

export function PermissionsSettingsRoute() {
  const { t } = useT("settings")
  const prefix = routePrefix(useLocation().pathname)
  usePageTitle(t("permissions.title"))
  const queryClient = useQueryClient()
  const query = useQuery({ queryKey, queryFn: fetchPermissions })
  const descriptors = query.data?.inherited ?? []
  const rules = (query.data?.rules ?? []).filter((rule) => !rule.revoked_at)
  const [view, setView] = useState<View>("matrix")
  const historyQuery = useQuery({ queryKey: ["permission_history"], queryFn: fetchPermissionHistory, enabled: view === "leases" || view === "history" })
  const subject: Subject = "interactive_chat"
  const [searchParams, setSearchParams] = useSearchParams()
  const [editor, setEditor] = useState<RuleEditorSeed | null>(null)
  const [savedNotice, setSavedNotice] = useState(false)
  const highlightedRuleId = Number(searchParams.get("rule")) || null
  const [selectedKeys, setSelectedKeys] = useState<string[]>([])
  const [selectedRuleIds, setSelectedRuleIds] = useState<number[]>([])
  const [preview, setPreview] = useState<{ rows: PermissionPreview[]; digest: string; operations: PermissionBulkOperation[] } | null>(null)
  const [profileSubject, setProfileSubject] = useState<Subject>("interactive_chat")
  const [profilePreview, setProfilePreview] = useState<{
    preview: Awaited<ReturnType<typeof previewPermissionProfile>>["preview"]
    digest: string
  } | null>(null)
  const role = roleFor(subject)
  // Capabilities that can carry a standing (permanent) rule for some role.
  const authorableCapabilities = useMemo(() => descriptors.filter((item) => item.requestable_roles.length > 0), [descriptors])
  const refresh = () => queryClient.invalidateQueries({ queryKey })
  const revoke = useMutation({ mutationFn: revokePermissionRule, onSuccess: refresh })
  const preset = useMutation({
    mutationFn: ({ item, name }: { item: InheritedPermission; name: string }) =>
      applyPermissionPreset({
        preset: name,
        role,
        subject_selector_type: subject,
        capability: item.capability,
        operation: item.operation,
        resource_scope: {},
        constraints: {}
      }),
    onSuccess: refresh
  })
  const bulkPreview = useMutation({
    mutationFn: (operations: PermissionBulkOperation[]) => previewPermissionBulk(operations),
    onSuccess: (result, operations) => setPreview({ rows: result.preview, digest: result.confirmation_digest, operations })
  })
  const bulkApply = useMutation({
    mutationFn: () => applyPermissionBulk(preview!.operations, preview!.digest),
    onSuccess: () => {
      setPreview(null)
      setSelectedKeys([])
      setSelectedRuleIds([])
      void refresh()
    }
  })
  const loadProfilePreview = useMutation({
    mutationFn: (profile: string) => previewPermissionProfile(profile, profileSubject),
    onSuccess: (result) => setProfilePreview({ preview: result.preview, digest: result.confirmation_digest })
  })
  const applyProfile = useMutation({
    mutationFn: () => applyPermissionProfile(profilePreview!.preview.profile.key, profileSubject, profilePreview!.digest),
    onSuccess: () => {
      setProfilePreview(null)
      void refresh()
    }
  })

  const startEdit = (rule: PermissionRule) => {
    setView("rules")
    setEditor({
      kind: "fields",
      replaceRuleId: rule.id,
      fields: {
        policy: rule.policy,
        duration: "permanent",
        subject_selector_type: rule.subject_selector_type,
        subject_selector_id: rule.subject_selector_id ?? "",
        subject_repository_id: rule.subject_repository_id ? String(rule.subject_repository_id) : "",
        role: rule.subject_role_keys?.[0] ?? "",
        capability: rule.capability,
        operation: rule.operation ?? "",
        resource_scope: rule.resource_scope,
        constraints: rule.constraints ?? {},
        rationale: rule.rationale ?? ""
      }
    })
  }
  const closeEditor = () => {
    setEditor(null)
    if (searchParams.has("request") || searchParams.has("item")) {
      const next = new URLSearchParams(searchParams)
      next.delete("request")
      next.delete("item")
      setSearchParams(next, { replace: true })
    }
  }
  // Deep links from authorization cards: ?request=&item= opens the editor
  // prefilled from that exact pending call; ?rule= focuses a rule in the list.
  const deepRequest = Number(searchParams.get("request")) || null
  const deepItem = Number(searchParams.get("item")) || null
  useEffect(() => {
    if (deepRequest && deepItem) {
      setView("rules")
      setEditor({ kind: "request", requestId: deepRequest, itemId: deepItem })
    } else if (highlightedRuleId) {
      setView("rules")
    }
  }, [deepRequest, deepItem, highlightedRuleId])
  const previewSelected = (nextPolicy: "allow" | "deny") => {
    const operations = descriptors
      .filter((item) => selectedKeys.includes(keyFor(item)))
      .map((item) => ({
        action: "grant" as const,
        policy: nextPolicy,
        role,
        subject_selector_type: subject,
        capability: item.capability,
        operation: item.operation,
        resource_scope: {},
        constraints: {}
      }))
    bulkPreview.mutate(operations)
  }
  const previewRevokes = () => bulkPreview.mutate(selectedRuleIds.map((id) => ({ action: "revoke" as const, id })))

  return (
    <main aria-label={t("permissions.title")} className="mx-auto max-w-7xl space-y-6 p-6">
      <header>
        <PageHeading>{t("permissions.title")}</PageHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("permissions.description")}</p>
        <Link className="mt-2 inline-block text-sm font-medium text-brand hover:underline" to={withRoutePrefix("/permissions/inbox", prefix)}>
          {t("permissions.approvals_link")}
        </Link>
      </header>
      {query.data ? (
        <section aria-labelledby="permission-profile-heading" className="rounded-xl border border-border bg-surface-raised p-5">
          <div className="flex flex-wrap items-end justify-between gap-3">
            <div>
              <SectionHeading id="permission-profile-heading">{t("permissions.profile_title")}</SectionHeading>
              <p className="mt-1 max-w-3xl text-sm text-text-secondary">{t("permissions.profile_help")}</p>
            </div>
            <label className="text-sm font-medium text-text-secondary">
              {t("permissions.profile_for")}
              <Select
                className="ml-2"
                fullWidth={false}
                onChange={(event) => {
                  setProfileSubject(event.target.value as Subject)
                  setProfilePreview(null)
                }}
                value={profileSubject}
              >
                {subjects.map((item) => (
                  <option key={item} value={item}>
                    {t(`permissions.subjects.${item}`)}
                  </option>
                ))}
              </Select>
            </label>
          </div>
          <div className="mt-4 grid gap-3 md:grid-cols-3">
            {query.data.profiles.map((profile) => {
              const selected = query.data.current_profiles[profileSubject] === profile.key
              return (
                <article className={`rounded-lg border p-4 ${selected ? "border-brand bg-brand-subtle" : "border-border bg-surface"}`} key={profile.key}>
                  <div className="flex items-center justify-between gap-2">
                    <h3 className="font-semibold text-text-primary">{profileCopy(profile, "name", t)}</h3>
                    {selected ? <span className="text-xs font-medium text-brand">{t("permissions.profile_active")}</span> : null}
                  </div>
                  <p className="mt-2 text-sm text-text-secondary">{profileCopy(profile, "description", t)}</p>
                  <p className="mt-3 text-xs text-text-muted">{profileCopy(profile, "boundary", t)}</p>
                  <button
                    className="mt-3 rounded-md border border-brand px-3 py-1.5 text-sm font-semibold text-brand disabled:opacity-60"
                    disabled={selected || loadProfilePreview.isPending || applyProfile.isPending}
                    onClick={() => loadProfilePreview.mutate(profile.key)}
                    type="button"
                  >
                    {selected ? t("permissions.profile_selected") : t("permissions.profile_select")}
                  </button>
                </article>
              )
            })}
          </div>
          {loadProfilePreview.isError || applyProfile.isError ? (
            <PanelMessage tone="error">{errorMessage(loadProfilePreview.error || applyProfile.error, t("permissions.profile_error"))}</PanelMessage>
          ) : null}
        </section>
      ) : null}
      {query.isError ? <PanelMessage tone="error">{t("permissions.load_error")}</PanelMessage> : null}
      {bulkPreview.isError || bulkApply.isError ? (
        <PanelMessage tone="error">{errorMessage(bulkPreview.error || bulkApply.error, t("permissions.create_error"))}</PanelMessage>
      ) : null}
      {revoke.isError ? <PanelMessage tone="error">{errorMessage(revoke.error, t("permissions.revoke_error"))}</PanelMessage> : null}
      <nav aria-label={t("permissions.views_label")} className="flex gap-2 border-b border-border">
        {(["matrix", "resources", "rules", "leases", "history", "ai_approval"] as View[]).map((item) => (
          <button
            className={`px-3 py-2 text-sm font-medium ${view === item ? "border-b-2 border-brand text-brand" : "text-text-secondary"}`}
            key={item}
            onClick={() => setView(item)}
          >
            {t(`permissions.views.${item}`)}
          </button>
        ))}
      </nav>

      {view === "ai_approval" ? <AiApprovalDelegations descriptors={descriptors} /> : null}

      {view === "matrix" ? (
        <section className="overflow-x-auto rounded-xl border border-border bg-surface-raised p-5">
          <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
            <div>
              <SectionHeading>{t("permissions.matrix_title")}</SectionHeading>
              <p className="mt-1 text-sm text-text-secondary">{t("permissions.matrix_help")}</p>
            </div>
            {selectedKeys.length ? (
              <div className="flex gap-2">
                <button className="rounded-md bg-brand px-3 py-2 text-sm font-semibold text-on-brand" onClick={() => previewSelected("allow")}>
                  {t("permissions.bulk_allow", { count: selectedKeys.length })}
                </button>
                <button className="rounded-md border border-danger px-3 py-2 text-sm font-semibold text-danger" onClick={() => previewSelected("deny")}>
                  {t("permissions.bulk_deny", { count: selectedKeys.length })}
                </button>
              </div>
            ) : null}
          </div>
          <DataTable.Root>
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>{t("permissions.capability")}</DataTable.HeadCell>
                {subjects.map((item) => (
                  <DataTable.HeadCell key={item}>{t(`permissions.subjects.${item}`)}</DataTable.HeadCell>
                ))}
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
              {descriptors.map((item) => (
                <DataTable.Row key={keyFor(item)}>
                  <DataTable.Cell>
                    <Checkbox
                      aria-label={t("permissions.select_capability", { capability: item.capability, operation: item.operation })}
                      checked={selectedKeys.includes(keyFor(item))}
                      label={
                        <span>
                          {item.presentation.capability_name} — {item.presentation.operation_name}
                          <span className="block text-sm font-normal text-text-secondary">{permissionDescription(item, t)}</span>
                          <code className="block text-xs text-text-muted">
                            {item.capability} · {item.operation}
                          </code>
                        </span>
                      }
                      onChange={() => setSelectedKeys(toggle(selectedKeys, keyFor(item)))}
                    />
                  </DataTable.Cell>
                  {subjects.map((cellSubject) => (
                    <DataTable.Cell key={cellSubject}>
                      <PolicyPill policy={item.matrix_states[cellSubject] ?? "deny"} t={t} />
                    </DataTable.Cell>
                  ))}
                </DataTable.Row>
              ))}
            </DataTable.Body>
          </DataTable.Root>
        </section>
      ) : null}
      {view === "resources" ? <ResourceView descriptors={descriptors} rules={rules} t={t} /> : null}
      {view === "leases" ? (
        <LeaseView descriptors={descriptors} leases={historyQuery.data?.active_leases ?? []} loading={historyQuery.isLoading} t={t} />
      ) : null}
      {view === "history" ? <HistoryView descriptors={descriptors} entries={historyQuery.data?.history ?? []} loading={historyQuery.isLoading} t={t} /> : null}
      {view === "rules" ? (
        <section className="rounded-xl border border-border bg-surface-raised p-5">
          <div className="flex items-center justify-between gap-3">
            <SectionHeading>{t("permissions.your_rules")}</SectionHeading>
            {selectedRuleIds.length ? (
              <button className="rounded-md border border-danger px-3 py-2 text-sm font-semibold text-danger" onClick={previewRevokes}>
                {t("permissions.bulk_revoke", { count: selectedRuleIds.length })}
              </button>
            ) : null}
          </div>
          <p className="mt-1 text-sm text-text-secondary">{t("permissions.your_rules_help")}</p>
          <div className="mt-4 space-y-3">
            {rules.map((rule) => (
              <article
                aria-current={rule.id === highlightedRuleId ? "true" : undefined}
                className={`flex flex-col gap-3 rounded-lg border p-4 sm:flex-row sm:items-center sm:justify-between ${rule.id === highlightedRuleId ? "border-brand bg-brand/5" : "border-border"}`}
                id={`permission-rule-${rule.id}`}
                key={rule.id}
              >
                <Checkbox
                  aria-label={t("permissions.select_rule", { capability: rule.capability, operation: rule.operation })}
                  checked={selectedRuleIds.includes(rule.id)}
                  onChange={() => setSelectedRuleIds(toggleNumber(selectedRuleIds, rule.id))}
                />
                <div>
                  <p className="font-medium text-text-primary">
                    {presentationLabel(rule.capability, rule.operation, descriptors) || t("permissions.all_operations")}
                    <code className="block text-xs font-normal text-text-muted">
                      {rule.capability} · {rule.operation}
                    </code>
                  </p>
                  <p className="mt-1 text-sm text-text-secondary">
                    {t("permissions.rule_summary", { policy: rule.policy, subject: t(`permissions.subjects.${rule.subject_selector_type}`) })}
                  </p>
                  <p className="mt-1 text-xs text-text-muted">
                    {rule.resource_scope_label} · {t("permissions.owned_by", { owner: rule.owner.name })}
                    {rule.rationale ? ` · ${rule.rationale}` : ""}
                  </p>
                </div>
                {rule.editable ? (
                  <div className="flex gap-2">
                    <button className="rounded-md border border-border px-3 py-1.5 text-sm" onClick={() => startEdit(rule)}>
                      {t("permissions.edit")}
                    </button>
                    <button
                      className="rounded-md border border-border px-3 py-1.5 text-sm font-medium text-danger"
                      disabled={revoke.isPending}
                      onClick={() => revoke.mutate(rule.id)}
                    >
                      {t("permissions.revoke")}
                    </button>
                  </div>
                ) : null}
              </article>
            ))}
            {rules.length === 0 ? <p className="text-sm text-text-muted">{t("permissions.no_rules")}</p> : null}
          </div>
          {editor ? (
            <div className="mt-5 border-t border-border pt-5">
              <PermissionRuleEditor
                headingLevel={3}
                key={editorKey(editor)}
                onApplied={() => {
                  closeEditor()
                  setSavedNotice(true)
                  void refresh()
                  void queryClient.invalidateQueries({ queryKey: ["permission_history"] })
                }}
                onCancel={closeEditor}
                seed={editor}
              />
            </div>
          ) : (
            <div className="mt-5 border-t border-border pt-5">
              <button
                className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-on-brand"
                onClick={() => {
                  setSavedNotice(false)
                  setEditor({ kind: "blank", capabilities: authorableCapabilities.map(({ capability, operation }) => ({ capability, operation })) })
                }}
                type="button"
              >
                {t("permission_editor.custom_rule")}
              </button>
              {savedNotice ? (
                <span className="ml-3 text-sm text-success" role="status">
                  {t("permission_editor.rule_saved")}
                </span>
              ) : null}
            </div>
          )}
        </section>
      ) : null}
      <section className="rounded-xl border border-border bg-surface-raised p-5">
        <SectionHeading>{t("permissions.inherited_policy")}</SectionHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("permissions.inherited_help")}</p>
        <div className="mt-4 divide-y divide-border">
          {descriptors.map((item) => (
            <InheritedRow item={item} key={keyFor(item)} onPreset={(name) => preset.mutate({ item, name })} t={t} />
          ))}
        </div>
      </section>
      <Modal label={t("permissions.profile_confirm_title")} onClose={() => setProfilePreview(null)} open={Boolean(profilePreview)}>
        {profilePreview ? (
          <div className="space-y-4">
            <SectionHeading>
              {t("permissions.profile_confirm_selection", {
                profile: profileCopy(profilePreview.preview.profile, "name", t),
                subject: t(`permissions.subjects.${profileSubject}`)
              })}
            </SectionHeading>
            <p className="text-sm text-text-secondary">{t("permissions.profile_confirm_body", { subject: t(`permissions.subjects.${profileSubject}`) })}</p>
            <div className="grid gap-3 md:grid-cols-2">
              <ProfileRuleList
                empty={t("permissions.profile_no_revocations")}
                heading={t("permissions.profile_revoked", { count: profilePreview.preview.revoked.length })}
                rows={profilePreview.preview.revoked}
                t={t}
              />
              <ProfileRuleList
                empty={t("permissions.profile_no_replacements")}
                heading={t("permissions.profile_replacements", { count: profilePreview.preview.replacements.length })}
                rows={profilePreview.preview.replacements}
                t={t}
              />
            </div>
            <p className="rounded-lg bg-warning-surface p-3 text-sm text-warning-text">{t("permissions.profile_confirm_boundary")}</p>
            <div className="flex flex-wrap gap-2">
              <button
                className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-on-brand"
                disabled={applyProfile.isPending}
                onClick={() => applyProfile.mutate()}
                type="button"
              >
                {applyProfile.isPending ? t("permissions.profile_applying") : t("permissions.profile_confirm")}
              </button>
              <button
                className="rounded-md border border-border px-4 py-2 text-sm font-semibold text-text-secondary"
                disabled={applyProfile.isPending}
                onClick={() => setProfilePreview(null)}
                type="button"
              >
                {t("permissions.profile_cancel")}
              </button>
            </div>
          </div>
        ) : null}
      </Modal>
      <BulkPreviewModal applying={bulkApply.isPending} onClose={() => setPreview(null)} onConfirm={() => bulkApply.mutate()} preview={preview} t={t} />
    </main>
  )
}

type ProfileRuleRow = { policy: string; capability: string; operation: string | null; resource_scope_label: string }

function ProfileRuleList({ empty, heading, rows, t }: { empty: string; heading: string; rows: ProfileRuleRow[]; t: Translate }) {
  return (
    <section className="rounded-lg border border-border p-3">
      <h3 className="text-sm font-semibold text-text-primary">{heading}</h3>
      {rows.length ? (
        <ul className="mt-2 max-h-48 space-y-2 overflow-y-auto">
          {rows.map((row, index) => (
            <li className="text-xs text-text-secondary" key={`${row.capability}-${row.operation}-${index}`}>
              <strong>{t(`permissions.states.${row.policy}`)}</strong> · {row.capability} · {row.operation || t("permissions.all_operations")}
              <br />
              <span className="text-text-muted">{row.resource_scope_label}</span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-2 text-xs text-text-muted">{empty}</p>
      )}
    </section>
  )
}

const profileTranslationKeys: Record<string, "full_access" | "ask_on_first_use" | "restricted"> = {
  "full_access@v1": "full_access",
  "ask_on_first_use@v1": "ask_on_first_use",
  "restricted@v1": "restricted"
}

function profileCopy(profile: { key: string; label: string; description: string }, kind: "name" | "description" | "boundary", t: Translate) {
  const key = profileTranslationKeys[profile.key]
  if (!key) return kind === "name" ? profile.label : profile.description
  const group = kind === "name" ? "profile_names" : kind === "description" ? "profile_descriptions" : "profile_boundaries"
  return t(`permissions.${group}.${key}`)
}

function ResourceView({ descriptors, rules, t }: { descriptors: InheritedPermission[]; rules: PermissionRule[]; t: Translate }) {
  const groups = rules.reduce<Record<string, PermissionRule[]>>((result, rule) => {
    const key = `${rule.resource_type}:${rule.resource_scope_label}`
    ;(result[key] ||= []).push(rule)
    return result
  }, {})
  return (
    <section className="rounded-xl border border-border bg-surface-raised p-5">
      <SectionHeading>{t("permissions.resources_title")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("permissions.resources_help")}</p>
      <div className="mt-4 grid gap-3 md:grid-cols-2">
        {Object.entries(groups).map(([label, items]) => (
          <article className="rounded-lg border border-border p-4" key={label}>
            <h3 className="font-medium">{items[0].resource_scope_label}</h3>
            <p className="text-xs text-text-muted">{items[0].resource_type}</p>
            <ul className="mt-2 space-y-1 text-sm">
              {items.map((rule) => (
                <li key={rule.id}>
                  <PolicyPill policy={rule.policy} t={t} />{" "}
                  <span className="ml-2">
                    {presentationLabel(rule.capability, rule.operation, descriptors) || t("permissions.unknown")}
                    <code className="block text-xs text-text-muted">
                      {rule.capability} · {rule.operation}
                    </code>
                  </span>
                </li>
              ))}
            </ul>
          </article>
        ))}
        {rules.length === 0 ? <p className="text-sm text-text-muted">{t("permissions.no_resources")}</p> : null}
      </div>
    </section>
  )
}

function LeaseView({ descriptors, leases, loading, t }: { descriptors: InheritedPermission[]; leases: PermissionLease[]; loading: boolean; t: Translate }) {
  return (
    <section className="rounded-xl border border-border bg-surface-raised p-5">
      <SectionHeading>{t("permissions.leases_title")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("permissions.leases_help")}</p>
      <div className="mt-4 space-y-3">
        {leases.map((lease) => (
          <article className="rounded-lg border border-border p-4" key={lease.id}>
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <h3 className="font-medium">{presentationLabel(lease.capability, lease.operation, descriptors) || t("permissions.all_operations")}</h3>
                <code className="block text-xs text-text-muted">
                  {lease.capability} · {lease.operation}
                </code>
                <p className="mt-1 text-sm text-text-secondary">{t("permissions.lease_lifecycle", { subject: lease.subject, duration: lease.duration })}</p>
              </div>
              <PolicyPill policy="allow" t={t} />
            </div>
            <dl className="mt-3 grid gap-2 text-xs text-text-muted sm:grid-cols-3">
              <div>
                <dt>{t("permissions.origin")}</dt>
                <dd className="text-text-primary">{lease.origin?.label || t("permissions.unknown")}</dd>
              </div>
              <div>
                <dt>{t("permissions.uses")}</dt>
                <dd className="text-text-primary">
                  {lease.max_uses == null ? t("permissions.uses_unlimited", { count: lease.used_count }) : `${lease.used_count} / ${lease.max_uses}`}
                </dd>
              </div>
              <div>
                <dt>{t("permissions.expires")}</dt>
                <dd className="text-text-primary">{formatTime(lease.expires_at, t)}</dd>
              </div>
            </dl>
          </article>
        ))}
        {!loading && leases.length === 0 ? <p className="text-sm text-text-muted">{t("permissions.no_leases")}</p> : null}
        {loading ? <p className="text-sm text-text-muted">{t("permissions.loading_history")}</p> : null}
      </div>
    </section>
  )
}

function HistoryView({
  descriptors,
  entries,
  loading,
  t
}: {
  descriptors: InheritedPermission[]
  entries: PermissionHistoryEntry[]
  loading: boolean
  t: Translate
}) {
  return (
    <section className="rounded-xl border border-border bg-surface-raised p-5">
      <SectionHeading>{t("permissions.history_title")}</SectionHeading>
      <p className="mt-1 text-sm text-text-secondary">{t("permissions.history_help")}</p>
      <ol className="mt-4 space-y-3">
        {entries.map((entry) => (
          <li className="rounded-lg border border-border p-4" key={`${entry.type}-${entry.id}`}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div>
                <h3 className="font-medium">{historyTitle(entry, descriptors, t)}</h3>
                {entry.capability ? (
                  <code className="block text-xs text-text-muted">
                    {String(entry.capability)}
                    {entry.operation ? ` · ${String(entry.operation)}` : ""}
                  </code>
                ) : null}
              </div>
              <time className="text-xs text-text-muted">{formatTime(entry.occurred_at, t)}</time>
            </div>
            <p className="mt-1 text-sm text-text-secondary">{t("permissions.history_state", { state: entry.state })}</p>
            {entry.type === "request" ? <RequestDetails entry={entry} t={t} /> : null}
            {entry.type === "invocation" ? <InvocationDetails entry={entry} t={t} /> : null}
            {entry.type === "policy_change" ? <Evidence evidence={entry.evidence} t={t} /> : null}
            {entry.type === "lease" ? (
              <p className="mt-2 text-xs text-text-muted">{t("permissions.lease_history", { used: entry.used_count, maximum: entry.max_uses ?? "∞" })}</p>
            ) : null}
          </li>
        ))}
        {!loading && entries.length === 0 ? <li className="text-sm text-text-muted">{t("permissions.no_history")}</li> : null}
        {loading ? <li className="text-sm text-text-muted">{t("permissions.loading_history")}</li> : null}
      </ol>
    </section>
  )
}

function RequestDetails({ entry, t }: { entry: PermissionHistoryEntry; t: Translate }) {
  const items = (entry.items as Array<Record<string, unknown>> | undefined) ?? []
  const origins = (entry.origins as Array<{ label: string }> | undefined) ?? []
  return (
    <div className="mt-2 space-y-2 text-xs text-text-muted">
      <p>{t("permissions.request_origin", { origin: origins.map((origin) => origin.label).join(", ") || t("permissions.unknown") })}</p>
      {entry.escalated ? <p className="font-medium text-warning">{t("permissions.escalated_request")}</p> : null}
      {entry.non_actionable_reason ? <p>{t("permissions.non_actionable", { reason: entry.non_actionable_reason })}</p> : null}
      {items.map((item) => (
        <div className="rounded-md bg-surface p-2" key={String(item.id)}>
          <p className="text-text-primary">
            {String(item.capability)} · {String(item.operation || "")}
          </p>
          <p>{t("permissions.decision", { state: item.state, duration: item.selected_duration || "—", reason: item.decision_reason || "—" })}</p>
          <Evidence evidence={item.evidence} t={t} />
        </div>
      ))}
    </div>
  )
}

function InvocationDetails({ entry, t }: { entry: PermissionHistoryEntry; t: Translate }) {
  return (
    <div className="mt-2 text-xs text-text-muted">
      <p>{t("permissions.execution", { tool: entry.tool_name, result: entry.result_status || entry.invalidation_reason || entry.state })}</p>
      <Evidence evidence={entry.evidence} t={t} />
    </div>
  )
}

function Evidence({ evidence, t }: { evidence: unknown; t: Translate }) {
  if (!evidence || (typeof evidence === "object" && Object.keys(evidence).length === 0)) return null
  return (
    <pre className="mt-2 overflow-x-auto whitespace-pre-wrap rounded bg-surface p-2 text-xs">
      {t("permissions.redacted_evidence")}: {JSON.stringify(evidence, null, 2)}
    </pre>
  )
}

function historyTitle(entry: PermissionHistoryEntry, descriptors: InheritedPermission[], t: Translate) {
  if (entry.type === "request") return t("permissions.history_types.request")
  if (entry.type === "invocation") return t("permissions.history_types.invocation", { tool: entry.tool_name })
  const name = entry.operation
    ? presentationFor(String(entry.capability), String(entry.operation), descriptors)?.operation_name || t("permissions.unknown")
    : presentationFor(String(entry.capability), null, descriptors)?.capability_name || t("permissions.unknown")
  if (entry.type === "policy_change") return t("permissions.history_types.policy_change", { capability: name })
  return t("permissions.history_types.lease", { capability: name })
}

function formatTime(value: unknown, t: Translate) {
  return typeof value === "string" && value ? new Date(value).toLocaleString() : t("permissions.never")
}
type BulkPreview = { rows: PermissionPreview[]; digest: string; operations: PermissionBulkOperation[] }

type BulkPreviewModalProps = {
  applying: boolean
  onClose: () => void
  onConfirm: () => void
  preview: BulkPreview | null
  t: Translate
}

function BulkPreviewModal({ applying, onClose, onConfirm, preview, t }: BulkPreviewModalProps) {
  return (
    <Modal label={t("permissions.confirm_bulk_title")} onClose={onClose} open={Boolean(preview)}>
      {preview ? (
        <>
          <SectionHeading>{t("permissions.confirm_bulk_title")}</SectionHeading>
          <p className="mt-1 text-sm text-text-secondary">{t("permissions.confirm_bulk_help", { count: preview.rows.length })}</p>
          <ul className="my-4 max-h-80 space-y-2 overflow-y-auto">
            {preview.rows.map((row: PermissionPreview, index: number) => (
              <li className="rounded-md border border-border p-2 text-sm" key={`${row.capability}-${row.operation}-${index}`}>
                <strong>{row.policy}</strong> · {row.subject}
                <br />
                {row.capability} · {row.operation}
                <br />
                <span className="text-xs text-text-muted">{row.resource_scope_label}</span>
              </li>
            ))}
          </ul>
          <div className="flex justify-end gap-2">
            <button className="rounded-md border border-border px-3 py-2 text-sm" onClick={onClose}>
              {t("permissions.cancel_bulk")}
            </button>
            <button className="rounded-md bg-brand px-3 py-2 text-sm font-semibold text-on-brand" disabled={applying} onClick={onConfirm}>
              {t("permissions.confirm_bulk")}
            </button>
          </div>
        </>
      ) : null}
    </Modal>
  )
}
function PolicyPill({ policy, t }: { policy: PolicyState; t: Translate }) {
  const tone = policy === "allow" ? "bg-success/10 text-success" : policy === "deny" ? "bg-danger/10 text-danger" : "bg-warning/10 text-warning"
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-semibold ${tone}`}>{t(`permissions.states.${policy}`)}</span>
}
function InheritedRow({ item, onPreset, t }: { item: InheritedPermission; onPreset: (name: string) => void; t: Translate }) {
  const defaults = Object.entries(item.defaults)
    .map(([role, policy]) => `${role}: ${policy}`)
    .join(", ")
  return (
    <div className="py-3">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className="font-medium">
            {item.presentation.capability_name} — {item.presentation.operation_name}
          </p>
          <p className="text-sm text-text-secondary">{permissionDescription(item, t)}</p>
          <code className="text-xs text-text-muted">
            {item.capability} · {item.operation}
          </code>
        </div>
        <span className="rounded-full bg-surface px-2 py-1 text-xs text-text-muted">{t("permissions.read_only")}</span>
      </div>
      <p className="mt-1 text-sm text-text-secondary">{defaults}</p>
      <p className="mt-1 text-xs text-text-muted">{t("permissions.decisive_explanation", { owner: item.owner.name })}</p>
      {item.presets?.length ? (
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <span className="text-xs text-text-muted">
            {t("permissions.presets_available", { presets: item.presets.map((preset) => preset.name).join(", ") })}
          </span>
          {item.presets.map((preset) => (
            <button className="rounded-md border border-border px-2 py-1 text-xs text-brand" key={preset.name} onClick={() => onPreset(preset.name)}>
              {t("permissions.apply_preset", { preset: preset.name })}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  )
}
function permissionDescription(item: InheritedPermission, t: Translate) {
  const effects = item.effects.map((effect) => t(`permissions.effect_descriptions.${effect}`)).join(" ")
  return [item.presentation.operation_description, effects].filter(Boolean).join(" ")
}
function presentationFor(capability: string, operation: string | null, descriptors: InheritedPermission[]) {
  return descriptors.find((item) => item.capability === capability && (!operation || item.operation === operation))?.presentation
}
function presentationLabel(capability: string, operation: string | null, descriptors: InheritedPermission[]) {
  const presentation = presentationFor(capability, operation, descriptors)
  return presentation ? `${presentation.capability_name} — ${presentation.operation_name}` : null
}
function keyFor(item: Pick<InheritedPermission, "capability" | "operation">) {
  return `${item.capability}:${item.operation}`
}
function roleFor(subject: string) {
  return subject === "interactive_chat" ? "chat:planner" : subject === "coding_chat" ? "chat:coding" : "chat:local"
}
function toggle(items: string[], item: string) {
  return items.includes(item) ? items.filter((value) => value !== item) : [...items, item]
}
function toggleNumber(items: number[], item: number) {
  return items.includes(item) ? items.filter((value) => value !== item) : [...items, item]
}

// A different seed must remount the editor so one rule's fields and preview
// can never be saved while replacing another rule.
function editorKey(seed: RuleEditorSeed) {
  if (seed.kind === "request") return `request-${seed.requestId}-${seed.itemId}`
  if (seed.kind === "fields") return `rule-${seed.replaceRuleId ?? "new"}`
  return "blank"
}
