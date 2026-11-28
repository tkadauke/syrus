import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { type ReactNode, useState } from "react"
import { Button } from "../components/Button"
import { Checkbox } from "../components/Checkbox"
import { Input } from "../components/Input"
import { NoticeToast } from "../components/NoticeToast"
import { Select } from "../components/Select"
import { Page } from "../components/ui"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { createNetworkRule, deleteNetworkRule, fetchRuntimeEnvironmentSettings, updateRuntimeEnvironmentSettings, type RuntimeEnvironmentPolicy } from "../api/runtimeEnvironmentSettings"

const queryKey = ["admin", "runtime_environment_settings"] as const

export function RuntimeEnvironmentSettings() {
  const { t } = useT("admin")
  const [notice, setNotice] = useState<string | null>(null)
  const query = useQuery({ queryKey, queryFn: fetchRuntimeEnvironmentSettings })
  return <Page.Root aria-label={t("aria_runtime_environment_settings")} gutter="responsive" size="wide">
    <Page.Header className="border-b border-border pb-4"><Page.HeadingGroup><p className="text-xs font-medium uppercase text-text-secondary">{t("section_label")}</p><Page.Title>{t("runtime_environment_settings.heading")}</Page.Title></Page.HeadingGroup></Page.Header>
    <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
    {query.isPending ? <p>{t("runtime_environment_settings.loading")}</p> : null}
    {query.isError ? <p className="text-danger" role="alert">{errorMessage(query.error, t("runtime_environment_settings.error_load"))}</p> : null}
    {query.data ? <SettingsForm initial={query.data} onNotice={setNotice} /> : null}
  </Page.Root>
}

function SettingsForm({ initial, onNotice }: { initial: Awaited<ReturnType<typeof fetchRuntimeEnvironmentSettings>>; onNotice: (message: string) => void }) {
  const { t } = useT("admin")
  const client = useQueryClient()
  const [registry, setRegistry] = useState({ url: initial.registry.url, repository_prefix: initial.registry.repository_prefix, builder_username: initial.registry.credentials.builder.username, builder_password: "", worker_username: initial.registry.credentials.worker.username, worker_password: "", admin_username: initial.registry.credentials.admin.username, admin_password: "" })
  const [policy, setPolicy] = useState(initial.policy)
  const save = useMutation({ mutationFn: () => updateRuntimeEnvironmentSettings({ registry, policy }), onSuccess: (value) => { client.setQueryData(queryKey, value); onNotice(value.message || t("runtime_environment_settings.updated")) } })
  const number = (section: keyof RuntimeEnvironmentPolicy, key: string, value: string) => setPolicy((current) => ({ ...current, [section]: { ...current[section], [key]: Number(value) } }))
  return <form className="space-y-6" onSubmit={(event) => { event.preventDefault(); save.mutate() }}>
    <Card title={t("runtime_environment_settings.registry_heading")} description={t("runtime_environment_settings.registry_description")}>
      <Grid><Field label={t("runtime_environment_settings.registry_url")} value={registry.url} onChange={(url) => setRegistry({ ...registry, url })} /><Field label={t("runtime_environment_settings.repository_prefix")} value={registry.repository_prefix} onChange={(repository_prefix) => setRegistry({ ...registry, repository_prefix })} /></Grid>
      <Grid>{(["builder", "worker", "admin"] as const).flatMap((role) => [<Field key={`${role}-user`} label={t("runtime_environment_settings.credential_username", { role })} value={registry[`${role}_username`]} onChange={(value) => setRegistry({ ...registry, [`${role}_username`]: value })} />, <Field key={`${role}-password`} label={t("runtime_environment_settings.credential_password", { role })} type="password" placeholder={initial.registry.credentials[role].password_set ? t("runtime_environment_settings.password_unchanged") : ""} value={registry[`${role}_password`]} onChange={(value) => setRegistry({ ...registry, [`${role}_password`]: value })} />])}</Grid>
    </Card>
    <Card title={t("runtime_environment_settings.builder_heading")} description={t("runtime_environment_settings.builder_description")}><Grid>
      {Object.entries(policy.builder).map(([key, value]) => <NumberField key={key} label={t(`runtime_environment_settings.${key}`)} value={value} onChange={(v) => number("builder", key, v)} />)}
    </Grid></Card>
    <NetworkRules initial={initial} />
    <Card title={t("runtime_environment_settings.verification_heading")} description={t("runtime_environment_settings.verification_description")}><Grid>
      <Field label={t("runtime_environment_settings.blocked_severities")} value={policy.verification.blocked_severities.join(", ")} onChange={(value) => setPolicy({ ...policy, verification: { ...policy.verification, blocked_severities: split(value) } })} />
      <Field label={t("runtime_environment_settings.prohibited_packages")} value={policy.verification.prohibited_packages.join(", ")} onChange={(value) => setPolicy({ ...policy, verification: { ...policy.verification, prohibited_packages: split(value) } })} />
    </Grid></Card>
    <Card title={t("runtime_environment_settings.lifecycle_heading")} description={t("runtime_environment_settings.lifecycle_description")}><Grid>
      <NumberField label={t("runtime_environment_settings.rollback_retention_days")} value={policy.base.rollback_retention_days} onChange={(v) => number("base", "rollback_retention_days", v)} />
      <Check label={t("runtime_environment_settings.abi_gate")} checked={policy.base.promotion_requires_compatible_abi} onChange={(checked) => setPolicy({ ...policy, base: { ...policy.base, promotion_requires_compatible_abi: checked } })} />
      <Check label={t("runtime_environment_settings.terminate_severe")} checked={policy.revocation.terminate_running_on_severe} onChange={(checked) => setPolicy({ ...policy, revocation: { terminate_running_on_severe: checked } })} />
    </Grid></Card>
    <Card title={t("runtime_environment_settings.cache_heading")} description={t("runtime_environment_settings.cache_description")}><Grid>
      {Object.entries(policy.cache).filter(([, value]) => typeof value === "number").map(([key, value]) => <NumberField key={key} label={t(`runtime_environment_settings.${key}`)} value={value as number} onChange={(v) => number("cache", key, v)} />)}
      <Check label={t("runtime_environment_settings.prefetch_active")} checked={policy.cache.prefetch_active} onChange={(checked) => setPolicy({ ...policy, cache: { ...policy.cache, prefetch_active: checked } })} />
    </Grid></Card>
    <Card title={t("runtime_environment_settings.scratch_heading")} description={t("runtime_environment_settings.scratch_description")}><Grid>
      <label className="text-sm text-text-primary">{t("runtime_environment_settings.mount_profile")}<Select className="mt-1" value={policy.runtime.mount_profile} onChange={(e) => setPolicy({ ...policy, runtime: { ...policy.runtime, mount_profile: e.target.value as "standard" | "executable_scratch" } })}><option value="standard">{t("runtime_environment_settings.scratch_disabled")}</option><option value="executable_scratch">{t("runtime_environment_settings.scratch_enabled")}</option></Select></label>
      <Field label={t("runtime_environment_settings.scratch_size")} value={policy.runtime.scratch_size} onChange={(scratch_size) => setPolicy({ ...policy, runtime: { ...policy.runtime, scratch_size } })} />
    </Grid></Card>
    {save.isError ? <p className="text-danger" role="alert">{errorMessage(save.error, t("runtime_environment_settings.error_save"))}</p> : null}<Button disabled={save.isPending} type="submit">{save.isPending ? t("runtime_environment_settings.saving") : t("runtime_environment_settings.save")}</Button>
  </form>
}

function NetworkRules({ initial }: { initial: Awaited<ReturnType<typeof fetchRuntimeEnvironmentSettings>> }) {
  const { t } = useT("admin"); const client = useQueryClient(); const [sourceClass, setSourceClass] = useState(initial.source_classes[0] || "os_package"); const [host, setHost] = useState(""); const [required, setRequired] = useState(false)
  const refresh = () => client.invalidateQueries({ queryKey }); const create = useMutation({ mutationFn: () => createNetworkRule({ source_class: sourceClass, host, required, enabled: true }), onSuccess: () => { setHost(""); void refresh() } }); const remove = useMutation({ mutationFn: deleteNetworkRule, onSuccess: () => void refresh() })
  return <Card title={t("runtime_environment_settings.network_heading")} description={t("runtime_environment_settings.network_description")}><div className="flex flex-wrap items-end gap-3"><label className="text-sm">{t("runtime_environment_settings.source_class")}<Select className="mt-1" value={sourceClass} onChange={(e) => setSourceClass(e.target.value)}>{initial.source_classes.map((key) => <option key={key} value={key}>{key}</option>)}</Select></label><Field label={t("runtime_environment_settings.host")} value={host} onChange={setHost} /><Check label={t("runtime_environment_settings.internal_mirror")} checked={required} onChange={(checked) => { setRequired(checked); if (checked) setSourceClass("internal_mirror") }} /><Button disabled={!host || create.isPending} onClick={() => create.mutate()} type="button">{t("runtime_environment_settings.add_rule")}</Button></div>{create.isError ? <p className="mt-2 text-sm text-danger" role="alert">{errorMessage(create.error, t("runtime_environment_settings.error_save"))}</p> : null}<ul className="mt-4 divide-y divide-border">{initial.network_rules.map((rule) => <li className="flex items-center justify-between py-2 text-sm" key={rule.id}><span>{rule.source_class}: {rule.host}{rule.required ? ` · ${t("runtime_environment_settings.required_mirror")}` : ""}</span><Button onClick={() => remove.mutate(rule.id)} size="sm" type="button" variant="danger">{t("runtime_environment_settings.remove")}</Button></li>)}</ul></Card>
}

const split = (value: string) => value.split(",").map((item) => item.trim().toLowerCase()).filter(Boolean)
function Card({ title, description, children }: { title: string; description: string; children: ReactNode }) { return <section className="rounded border border-border bg-surface p-5"><h2 className="font-semibold text-text-primary">{title}</h2><p className="mb-4 mt-1 text-sm text-text-secondary">{description}</p>{children}</section> }
function Grid({ children }: { children: ReactNode }) { return <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{children}</div> }
function Field({ label, value, onChange, type = "text", placeholder }: { label: string; value: string; onChange: (value: string) => void; type?: string; placeholder?: string }) { return <label className="text-sm text-text-primary">{label}<Input className="mt-1" onChange={(e) => onChange(e.target.value)} placeholder={placeholder} type={type} value={value} /></label> }
function NumberField({ label, value, onChange }: { label: string; value: number; onChange: (value: string) => void }) { return <Field label={label} onChange={onChange} type="number" value={String(value)} /> }
function Check({ label, checked, onChange }: { label: string; checked: boolean; onChange: (value: boolean) => void }) { return <label className="flex items-center gap-2 text-sm text-text-primary"><Checkbox checked={checked} onChange={(e) => onChange(e.target.checked)} />{label}</label> }
