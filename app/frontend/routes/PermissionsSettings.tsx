import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link } from "react-router-dom"
import {
  applyPermissionBulk,
  applyPermissionPreset,
  createPermissionRule,
  fetchPermissions,
  previewPermissionBulk,
  revokePermissionRule,
  updatePermissionRule,
  type InheritedPermission,
  type PermissionBulkOperation,
  type PermissionPreview,
  type PermissionRule
} from "../api/permissions"
import { Input } from "../components/Input"
import { Modal } from "../components/Modal"
import { PageHeading, SectionHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { Select } from "../components/Select"
import { Checkbox, DataTable } from "../components/ui"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["permission_rules"] as const
const subjects = ["interactive_chat", "coding_chat", "local_chat"] as const
type Subject = (typeof subjects)[number]
type View = "matrix" | "resources" | "rules"

export function PermissionsSettingsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("permissions.title"))
  const queryClient = useQueryClient()
  const query = useQuery({ queryKey, queryFn: fetchPermissions })
  const descriptors = query.data?.inherited ?? []
  const rules = (query.data?.rules ?? []).filter((rule) => !rule.revoked_at)
  const [view, setView] = useState<View>("matrix")
  const [subject, setSubject] = useState<Subject>("interactive_chat")
  const [descriptorKey, setDescriptorKey] = useState("")
  const [policy, setPolicy] = useState<"allow" | "deny">("allow")
  const [rationale, setRationale] = useState("")
  const [editing, setEditing] = useState<PermissionRule | null>(null)
  const [selectedKeys, setSelectedKeys] = useState<string[]>([])
  const [selectedRuleIds, setSelectedRuleIds] = useState<number[]>([])
  const [preview, setPreview] = useState<{ rows: PermissionPreview[]; digest: string; operations: PermissionBulkOperation[] } | null>(null)
  const role = roleFor(subject)
  const editableDescriptors = useMemo(
    () => descriptors.filter((item) => item.requestable_roles.includes(role) && (policy === "deny" || item.authority_durations.includes("permanent"))),
    [descriptors, policy, role]
  )
  const selected = editableDescriptors.find((item) => keyFor(item) === descriptorKey) ?? editableDescriptors[0]
  const refresh = () => queryClient.invalidateQueries({ queryKey })
  const payload = () => ({
    policy,
    role,
    subject_selector_type: subject,
    capability: selected.capability,
    operation: selected.operation,
    resource_scope: editing?.resource_scope ?? {},
    constraints: {},
    rationale
  })
  const save = useMutation({
    mutationFn: () => (editing ? updatePermissionRule(editing.id, payload()) : createPermissionRule(payload())),
    onSuccess: () => {
      setEditing(null)
      setRationale("")
      void refresh()
    }
  })
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

  const startEdit = (rule: PermissionRule) => {
    setEditing(rule)
    setSubject(rule.subject_selector_type as Subject)
    setDescriptorKey(`${rule.capability}:${rule.operation}`)
    setPolicy(rule.policy === "deny" ? "deny" : "allow")
    setRationale(rule.rationale ?? "")
  }
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
        <Link className="mt-2 inline-block text-sm font-medium text-brand hover:underline" to="/dashboard">
          {t("permissions.approvals_link")}
        </Link>
      </header>
      {query.isError ? <PanelMessage tone="error">{t("permissions.load_error")}</PanelMessage> : null}
      {save.isError || bulkPreview.isError || bulkApply.isError ? (
        <PanelMessage tone="error">{errorMessage(save.error || bulkPreview.error || bulkApply.error, t("permissions.create_error"))}</PanelMessage>
      ) : null}
      {revoke.isError ? <PanelMessage tone="error">{errorMessage(revoke.error, t("permissions.revoke_error"))}</PanelMessage> : null}
      <nav aria-label={t("permissions.views_label")} className="flex gap-2 border-b border-border">
        {(["matrix", "resources", "rules"] as View[]).map((item) => (
          <button
            className={`px-3 py-2 text-sm font-medium ${view === item ? "border-b-2 border-brand text-brand" : "text-text-secondary"}`}
            key={item}
            onClick={() => setView(item)}
          >
            {t(`permissions.views.${item}`)}
          </button>
        ))}
      </nav>

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
                          {item.capability}
                          <span className="block text-xs text-text-muted">{item.operation}</span>
                        </span>
                      }
                      onChange={() => setSelectedKeys(toggle(selectedKeys, keyFor(item)))}
                    />
                  </DataTable.Cell>
                  {subjects.map((cellSubject) => (
                    <DataTable.Cell key={cellSubject}>
                      <PolicyPill policy={effectivePolicy(item, cellSubject, rules)} />
                    </DataTable.Cell>
                  ))}
                </DataTable.Row>
              ))}
            </DataTable.Body>
          </DataTable.Root>
        </section>
      ) : null}
      {view === "resources" ? <ResourceView rules={rules} t={t} /> : null}
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
              <article className="flex flex-col gap-3 rounded-lg border border-border p-4 sm:flex-row sm:items-center sm:justify-between" key={rule.id}>
                <Checkbox
                  aria-label={t("permissions.select_rule", { capability: rule.capability, operation: rule.operation })}
                  checked={selectedRuleIds.includes(rule.id)}
                  onChange={() => setSelectedRuleIds(toggleNumber(selectedRuleIds, rule.id))}
                />
                <div>
                  <p className="font-medium text-text-primary">
                    {rule.capability} · {rule.operation || t("permissions.all_operations")}
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
          {selected ? (
            <RuleForm
              descriptors={editableDescriptors}
              editing={editing}
              policy={policy}
              rationale={rationale}
              selected={selected}
              subject={subject}
              t={t}
              onCancel={() => setEditing(null)}
              onDescriptor={setDescriptorKey}
              onPolicy={setPolicy}
              onRationale={setRationale}
              onSubject={setSubject}
              onSubmit={() => save.mutate()}
              pending={save.isPending}
            />
          ) : null}
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
      <BulkPreviewModal applying={bulkApply.isPending} onClose={() => setPreview(null)} onConfirm={() => bulkApply.mutate()} preview={preview} t={t} />
    </main>
  )
}

function RuleForm({
  descriptors,
  editing,
  policy,
  rationale,
  selected,
  subject,
  t,
  onCancel,
  onDescriptor,
  onPolicy,
  onRationale,
  onSubject,
  onSubmit,
  pending
}: any) {
  return (
    <form
      className="mt-5 grid gap-3 border-t border-border pt-5 md:grid-cols-2"
      onSubmit={(event) => {
        event.preventDefault()
        onSubmit()
      }}
    >
      <label className="text-sm font-medium">
        {t("permissions.subject")}
        <Select className="mt-1" onChange={(event) => onSubject(event.target.value)} value={subject}>
          {subjects.map((item) => (
            <option key={item} value={item}>
              {t(`permissions.subjects.${item}`)}
            </option>
          ))}
        </Select>
      </label>
      <label className="text-sm font-medium">
        {t("permissions.capability")}
        <Select className="mt-1" onChange={(event) => onDescriptor(event.target.value)} value={keyFor(selected)}>
          {descriptors.map((item: InheritedPermission) => (
            <option key={keyFor(item)} value={keyFor(item)}>
              {item.capability} · {item.operation}
            </option>
          ))}
        </Select>
      </label>
      <label className="text-sm font-medium">
        {t("permissions.policy")}
        <Select className="mt-1" onChange={(event) => onPolicy(event.target.value)} value={policy}>
          <option value="allow">{t("permissions.allow")}</option>
          <option value="deny">{t("permissions.deny")}</option>
        </Select>
      </label>
      <label className="text-sm font-medium">
        {t("permissions.rationale")}
        <Input className="mt-1" onChange={(event) => onRationale(event.target.value)} value={rationale} />
      </label>
      <div className="flex gap-2">
        <button className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-on-brand disabled:opacity-50" disabled={pending} type="submit">
          {editing ? t("permissions.save_rule") : t("permissions.add_rule")}
        </button>
        {editing ? (
          <button className="rounded-md border border-border px-4 py-2 text-sm" onClick={onCancel} type="button">
            {t("permissions.cancel_edit")}
          </button>
        ) : null}
      </div>
    </form>
  )
}
function ResourceView({ rules, t }: { rules: PermissionRule[]; t: any }) {
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
                  <PolicyPill policy={rule.policy} />{" "}
                  <span className="ml-2">
                    {rule.capability} · {rule.operation}
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
function BulkPreviewModal({ applying, onClose, onConfirm, preview, t }: any) {
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
function PolicyPill({ policy }: { policy: string }) {
  const tone = policy === "allow" ? "bg-success/10 text-success" : policy === "deny" ? "bg-danger/10 text-danger" : "bg-warning/10 text-warning"
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-semibold ${tone}`}>{policy}</span>
}
function InheritedRow({ item, onPreset, t }: { item: InheritedPermission; onPreset: (name: string) => void; t: any }) {
  const defaults = Object.entries(item.defaults)
    .map(([role, policy]) => `${role}: ${policy}`)
    .join(", ")
  return (
    <div className="py-3">
      <div className="flex items-center justify-between gap-3">
        <p className="font-medium">
          {item.capability} · {item.operation}
        </p>
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
function effectivePolicy(item: InheritedPermission, subject: Subject, rules: PermissionRule[]) {
  return (
    rules.find((rule) => rule.subject_selector_type === subject && rule.capability === item.capability && rule.operation === item.operation)?.policy ??
    item.defaults[roleFor(subject)] ??
    "deny"
  )
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
