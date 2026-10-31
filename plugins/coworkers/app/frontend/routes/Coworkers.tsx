import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { FormEvent, useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { Avatar } from "@app/components/Avatar"
import { AvatarPicker } from "@app/components/AvatarPicker"
import { ColorPicker } from "@app/components/ColorPicker"
import { Checkbox } from "@app/components/Checkbox"
import { Input } from "@app/components/Input"
import { Select } from "@app/components/Select"
import { Textarea } from "@app/components/Textarea"
import { PageHeading } from "@app/components/Heading"
import { PanelMessage } from "@app/components/PanelMessage"
import { FilterBar, type FilterLinkBuilder, type FilterTree } from "@app/components/FilterBar"
import { Page } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { Markdown } from "@app/lib/Markdown"
import { withRoutePrefix } from "@app/lib/routing"
import { defaultAccentSelection, type AccentSelection } from "@app/lib/appearance"
import {
  addCoworkerToChat,
  commandCoworkerSchedule,
  createCoworkerSchedule,
  createCoworker,
  createSideChat,
  fetchCoworker,
  fetchCoworkerActivity,
  fetchCoworkerApprovals,
  fetchCoworkerMemory,
  fetchCoworkerWorkspace,
  fetchCoworkers,
  removeCoworkerFromChat,
  retryProvisioningCleanup,
  acknowledgeProvisioningCleanup,
  decideCoworkerApproval,
  testCoworkerRemote,
  updateCoworkerGrant,
  type CoworkerDetail,
  type CoworkerMemoryFile,
  type CoworkerSummary
} from "../api/coworkers"

export default function CoworkersRoute() {
  const { id } = useParams()
  const location = useLocation()
  if (location.pathname.endsWith("/new")) return <NewCoworker />
  if (id) return <CoworkerPage id={id} />
  return <CoworkerList />
}

function usePrefix() {
  return useLocation().pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function CoworkerList() {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  const query = useQuery({ queryKey: ["coworkers"], queryFn: fetchCoworkers })
  const queryClient = useQueryClient()
  const retryCleanup = useMutation({ mutationFn: retryProvisioningCleanup, onSuccess: () => queryClient.invalidateQueries({ queryKey: ["coworkers"] }) })
  const acknowledgeCleanup = useMutation({
    mutationFn: acknowledgeProvisioningCleanup,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["coworkers"] })
  })
  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header className="flex items-center justify-between">
        <PageHeading>{t("title")}</PageHeading>
        <Link className="rounded bg-brand px-3 py-2 text-sm font-medium text-white" to={`${prefix}/coworkers/new`}>
          {t("new.action")}
        </Link>
      </Page.Header>
      {query.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {query.isError ? <PanelMessage>{t("error")}</PanelMessage> : null}
      {query.data?.provisioning_attempts?.length ? (
        <section className="mb-5 rounded border border-warning bg-surface p-4">
          <h2 className="font-semibold text-text-primary">{t("provisioning.title")}</h2>
          <div className="mt-3 space-y-3">
            {query.data.provisioning_attempts.map((attempt) => (
              <div className="flex flex-wrap items-center justify-between gap-3 text-sm" key={attempt.id}>
                <div>
                  <span className="font-medium">@{attempt.handle}</span> · {t(`provisioning.states.${attempt.state}`)}
                  {attempt.last_error ? <div className="text-text-secondary">{attempt.last_error}</div> : null}
                </div>
                <div className="flex gap-2">
                  {attempt.state === "cleanup_pending" ? (
                    <button className="rounded border border-border px-2 py-1" onClick={() => retryCleanup.mutate(attempt.id)}>
                      {t("provisioning.retry")}
                    </button>
                  ) : null}
                  {attempt.state === "manual_attention" && !attempt.acknowledged_at ? (
                    <button className="rounded border border-border px-2 py-1" onClick={() => acknowledgeCleanup.mutate(attempt.id)}>
                      {t("provisioning.acknowledge")}
                    </button>
                  ) : null}
                </div>
              </div>
            ))}
          </div>
        </section>
      ) : null}
      {query.data ? (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          <CoworkerCard coworker={query.data.syrus} prefix={prefix} />
          {query.data.coworkers.map((coworker) => (
            <CoworkerCard coworker={coworker} prefix={prefix} key={coworker.id} />
          ))}
        </div>
      ) : null}
    </Page.Root>
  )
}

function CoworkerCard({ coworker, prefix }: { coworker: CoworkerSummary; prefix: string }) {
  const { t } = useT("coworkers")
  return (
    <Link className="rounded border border-border bg-surface p-4 hover:border-brand" style={{ borderLeftWidth: 4 }} to={withRoutePrefix(coworker.path, prefix)}>
      <div className="flex gap-3">
        <Avatar avatarUrl={coworker.avatar_url} avatarKey={coworker.avatar_key} accentHex={coworker.accent_hex} name={coworker.name} />
        <div>
          <div className="font-semibold text-text-primary">{coworker.name}</div>
          <div className="text-sm text-text-secondary">@{coworker.handle}</div>
          <div className="mt-2 text-sm text-text-secondary">{coworker.role_summary}</div>
          {coworker.weekly_spend_usd != null ? (
            <div className="mt-2 text-sm font-medium text-text-primary">{t("card.weekly_spend", { amount: coworker.weekly_spend_usd.toFixed(2) })}</div>
          ) : null}
          {coworker.built_in ? <span className="mt-2 inline-block rounded bg-surface-subtle px-2 py-0.5 text-xs">{t("built_in")}</span> : null}
        </div>
      </div>
    </Link>
  )
}

function NewCoworker() {
  const { t } = useT("coworkers")
  const navigate = useNavigate()
  const prefix = usePrefix()
  const [color, setColor] = useState<AccentSelection>(() => defaultAccentSelection())
  const [colorEdited, setColorEdited] = useState(false)
  const [avatar, setAvatar] = useState<string | null>(null)
  const [remote, setRemote] = useState("")
  const [modelSelection, setModelSelection] = useState("")
  const [colorPopupOpen, setColorPopupOpen] = useState(false)
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const optionsQuery = useQuery({ queryKey: ["coworkers"], queryFn: fetchCoworkers })
  const mutation = useMutation({ mutationFn: createCoworker, onSuccess: (data) => navigate(withRoutePrefix(data.redirect_to, prefix)) })
  const remoteTest = useMutation({ mutationFn: () => testCoworkerRemote(remote) })
  useEffect(() => {
    if (optionsQuery.data && !colorEdited) setColor(defaultAccentSelection(optionsQuery.data.coworkers.map((coworker) => coworker.accent_hex)))
  }, [colorEdited, optionsQuery.data])
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    form.set("accent_hex", color.accentHex)
    form.set("idempotency_key", idempotencyKey)
    if (modelSelection) {
      const [chatProvider, chatModel] = modelSelection.split(":", 2)
      form.set("chat_provider", chatProvider)
      form.set("chat_model", chatModel)
    }
    if (avatar) form.set("avatar_key", avatar)
    mutation.mutate(form)
  }
  return (
    <Page.Root gutter="responsive" size="narrow">
      <Page.Header>
        <Link className="text-sm text-brand" to={`${prefix}/coworkers`}>
          {t("title")}
        </Link>
        <PageHeading>{t("new.title")}</PageHeading>
      </Page.Header>
      <form className="space-y-5 rounded border border-border bg-surface p-5" onSubmit={submit}>
        <Field label={t("fields.name")} name="name" required />
        <Field label={t("fields.handle")} name="handle" required pattern="[a-z0-9_-]{3,32}" />
        <label className="block text-sm font-medium">
          {t("fields.model")}
          <Select className="mt-1" onChange={(event) => setModelSelection(event.target.value)} value={modelSelection}>
            <option value="">{t("detail.account_default")}</option>
            {(optionsQuery.data?.model_options || []).map((provider) => (
              <optgroup key={provider.provider} label={provider.provider_label}>
                {provider.models.map((model) => (
                  <option key={model.id} value={`${provider.provider}:${model.id}`}>
                    {model.label}
                  </option>
                ))}
              </optgroup>
            ))}
          </Select>
        </label>
        <label className="block text-sm font-medium">
          {t("fields.remote")}
          <Input
            className="mt-1"
            name="workspace_repo"
            onChange={(event) => setRemote(event.target.value)}
            placeholder="https://github.com/owner/repository"
            required
            type="url"
          />
        </label>
        <div>
          <button
            className="rounded border border-border px-3 py-2 text-sm"
            disabled={!remote || remoteTest.isPending}
            onClick={() => remoteTest.mutate()}
            type="button"
          >
            {t("new.test_push")}
          </button>
          {remoteTest.isSuccess ? <span className="ml-2 text-sm text-success">{t("new.push_ok")}</span> : null}
          {remoteTest.isError ? <span className="ml-2 text-sm text-danger">{remoteTest.error.message}</span> : null}
        </div>
        <div className="relative">
          <label className="mb-2 block text-sm font-medium">{t("fields.color")}</label>
          <button
            aria-expanded={colorPopupOpen}
            aria-haspopup="dialog"
            className="flex items-center gap-2 rounded border border-border bg-surface px-3 py-2 text-sm"
            onClick={() => setColorPopupOpen((open) => !open)}
            type="button"
          >
            <span className="h-5 w-5 rounded-full border border-border" style={{ backgroundColor: color.accentHex }} />
            {color.accentHex}
          </button>
          {colorPopupOpen ? (
            <div
              aria-label={t("fields.color")}
              className="absolute left-0 z-20 mt-2 w-[min(90vw,36rem)] rounded border border-border bg-surface p-3 shadow-lg"
              role="dialog"
            >
              <ColorPicker
                ariaLabel={t("fields.color")}
                mode="light"
                accentRef={color.accentRef}
                name={t("new.title")}
                value={color.accentHex}
                onChange={(selection) => {
                  setColor(selection)
                  setColorEdited(true)
                }}
              />
            </div>
          ) : null}
        </div>
        <div>
          <label className="mb-2 block text-sm font-medium">{t("fields.avatar")}</label>
          <AvatarPicker ariaLabel={t("fields.avatar")} value={avatar} onChange={setAvatar} />
          <Input accept="image/*" className="mt-3" name="avatar" type="file" />
        </div>
        <fieldset>
          <legend className="mb-2 text-sm font-medium">{t("fields.grants")}</legend>
          {(optionsQuery.data?.grant_catalog || []).map((grant) => (
            <Checkbox className="mb-2" defaultChecked={grant.default_enabled} key={grant.name} label={grant.label} name="grants[]" value={grant.name} />
          ))}
        </fieldset>
        <label className="block text-sm font-medium">
          {t("fields.about")}
          <Textarea className="mt-1 min-h-28" name="about" />
        </label>
        {mutation.isError ? <PanelMessage>{mutation.error.message}</PanelMessage> : null}
        <button className="rounded bg-brand px-4 py-2 font-medium text-white" disabled={mutation.isPending}>
          {t("new.create")}
        </button>
      </form>
    </Page.Root>
  )
}

function Field({ label, ...props }: { label: string; name: string; required?: boolean; pattern?: string; type?: string; placeholder?: string }) {
  return (
    <label className="block text-sm font-medium">
      {label}
      <Input {...props} className="mt-1" />
    </label>
  )
}

function CoworkerPage({ id }: { id: string }) {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  const navigate = useNavigate()
  const [tab, setTab] = useState(id === "syrus" ? "chats" : "chat")
  const query = useQuery({ queryKey: ["coworkers", id], queryFn: () => fetchCoworker(id), enabled: id !== "syrus" })
  const sideChat = useMutation({ mutationFn: () => createSideChat(Number(id)), onSuccess: (data) => navigate(withRoutePrefix(data.chat_path, prefix)) })
  const [selectedChatId, setSelectedChatId] = useState("")
  const roster = useMutation({
    mutationFn: ({ chatId, add }: { chatId: number; add: boolean }) =>
      add ? addCoworkerToChat(Number(id), chatId) : removeCoworkerFromChat(Number(id), chatId),
    onSuccess: () => void query.refetch()
  })
  if (id === "syrus") return <SyrusPage tab={tab} setTab={setTab} />
  if (query.isPending) return <PanelMessage>{t("loading")}</PanelMessage>
  if (!query.data) return <PanelMessage>{t("error")}</PanelMessage>
  const coworker = query.data.coworker
  const selectedChat = coworker.available_chats.find((chat) => chat.id === Number(selectedChatId))
  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header>
        <Link className="text-sm text-brand" to={`${prefix}/coworkers`}>
          {t("title")}
        </Link>
        <div className="mt-3 flex items-center gap-3">
          <Avatar avatarUrl={coworker.avatar_url} avatarKey={coworker.avatar_key} accentHex={coworker.accent_hex} name={coworker.name} size="large" />
          <div>
            <PageHeading>{coworker.name}</PageHeading>
            <div className="text-text-secondary">@{coworker.handle}</div>
          </div>
        </div>
      </Page.Header>
      <Tabs active={tab} setActive={setTab} labels={["chat", "profile", "capabilities", "approvals", "schedule", "memory", "workspace", "activity"]} />
      {tab === "chat" ? (
        <section className="space-y-3">
          <div className="flex flex-wrap items-center gap-2 rounded border border-border bg-surface p-3">
            <Select aria-label={t("detail.add_to_chat")} onChange={(event) => setSelectedChatId(event.target.value)} value={selectedChatId}>
              <option value="">{t("detail.choose_chat")}</option>
              {coworker.available_chats.map((chat) => (
                <option key={chat.id} value={chat.id}>
                  {chat.title}
                  {chat.rostered || chat.implicit ? ` — ${t("detail.on_roster")}` : ""}
                </option>
              ))}
            </Select>
            <button
              className="rounded border border-border px-3 py-2 text-sm disabled:opacity-50"
              disabled={!selectedChatId || roster.isPending || selectedChat?.rostered || selectedChat?.implicit}
              onClick={() => roster.mutate({ chatId: Number(selectedChatId), add: true })}
              type="button"
            >
              {t("detail.add_to_chat")}
            </button>
            {selectedChat?.rostered ? (
              <button
                className="rounded border border-border px-3 py-2 text-sm"
                disabled={roster.isPending}
                onClick={() => roster.mutate({ chatId: Number(selectedChatId), add: false })}
                type="button"
              >
                {t("detail.remove_from_chat")}
              </button>
            ) : null}
          </div>
          <button className="rounded bg-brand px-3 py-2 text-sm text-white" onClick={() => sideChat.mutate()}>
            {t("detail.new_side_chat")}
          </button>
          {coworker.chats.map((chat) => (
            <Link className="block rounded border border-border bg-surface p-3 text-brand" key={chat.id} to={withRoutePrefix(chat.path, prefix)}>
              {chat.role === "main" ? t("detail.main_chat") : chat.title}
            </Link>
          ))}
        </section>
      ) : null}
      {tab === "profile" ? (
        <section className="space-y-4 rounded border border-border bg-surface p-5">
          <dl>
            <dt>{t("fields.model")}</dt>
            <dd>{coworker.effective_model || t("detail.account_default")}</dd>
            <dt>{t("fields.remote")}</dt>
            <dd>{coworker.workspace_repo}</dd>
          </dl>
          <h2 className="font-semibold">{t("detail.soul_heading")}</h2>
          <div className="whitespace-pre-wrap rounded bg-surface-subtle p-4 text-sm">{coworker.soul || t("detail.soul_unavailable")}</div>
        </section>
      ) : null}
      {tab === "capabilities" ? <CoworkerCapabilities coworker={coworker} onChanged={() => void query.refetch()} /> : null}
      {tab === "approvals" ? <CoworkerApprovals id={id} /> : null}
      {tab === "schedule" ? <CoworkerSchedules coworker={coworker} onChanged={() => void query.refetch()} /> : null}
      {tab === "memory" ? <CoworkerMemory id={id} /> : null}
      {tab === "workspace" ? <CoworkerWorkspace id={id} remote={coworker.workspace_repo} /> : null}
      {tab === "activity" ? <CoworkerActivity id={id} traffic={coworker.message_traffic} /> : null}
      {!["chat", "profile", "capabilities", "approvals", "schedule", "memory", "workspace", "activity"].includes(tab) ? (
        <PanelMessage>{t("coming_later")}</PanelMessage>
      ) : null}
    </Page.Root>
  )
}

function CoworkerApprovals({ id }: { id: string }) {
  const { t } = useT("coworkers")
  const queryClient = useQueryClient()
  const query = useQuery({ queryKey: ["coworkers", id, "approvals"], queryFn: () => fetchCoworkerApprovals(id) })
  const decision = useMutation({
    mutationFn: ({ approvalId, value }: { approvalId: number; value: "approve" | "reject" }) => decideCoworkerApproval(id, approvalId, value),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["coworkers", id, "approvals"] })
      void queryClient.invalidateQueries({ queryKey: ["sidebar_badge", "coworkers.index"] })
    }
  })
  if (query.isPending) return <PanelMessage>{t("approvals.loading")}</PanelMessage>
  if (!query.data?.approvals.length) return <PanelMessage>{t("approvals.empty")}</PanelMessage>
  return (
    <section className="space-y-3">
      {query.data.approvals.map((approval) => (
        <article className="rounded border border-border bg-surface p-4" key={approval.id}>
          <h2 className="font-semibold">{approval.tool_name}</h2>
          <div className="mt-1 text-sm text-text-secondary">
            {approval.run_id ? t("approvals.run", { id: approval.run_id }) : t("approvals.chat", { id: approval.chat_id })}
          </div>
          <pre className="mt-3 overflow-x-auto rounded bg-surface-subtle p-3 text-xs">{JSON.stringify(approval.tool_input, null, 2)}</pre>
          <div className="mt-3 flex gap-2">
            <button
              className="rounded bg-brand px-3 py-2 text-sm text-white"
              disabled={decision.isPending}
              onClick={() => decision.mutate({ approvalId: approval.id, value: "approve" })}
            >
              {t("approvals.approve")}
            </button>
            <button
              className="rounded border border-border px-3 py-2 text-sm"
              disabled={decision.isPending}
              onClick={() => decision.mutate({ approvalId: approval.id, value: "reject" })}
            >
              {t("approvals.reject")}
            </button>
          </div>
        </article>
      ))}
    </section>
  )
}

const POLICY_RANK = { off: 0, queue: 1, confirm: 2, auto: 3 } as const

function CoworkerCapabilities({ coworker, onChanged }: { coworker: CoworkerDetail; onChanged: () => void }) {
  const { t } = useT("coworkers")
  const [paths, setPaths] = useState(coworker.grants.find((grant) => grant.capability === "workspace.files")?.constraints.confirm_paths?.join(", ") || "")
  const mutation = useMutation({
    mutationFn: ({ capability, policy, confirmed }: { capability: string; policy: string; confirmed: boolean }) =>
      updateCoworkerGrant(
        String(coworker.id),
        capability,
        policy,
        capability === "workspace.files"
          ? {
              confirm_paths: paths
                .split(",")
                .map((path) => path.trim())
                .filter(Boolean)
            }
          : {},
        confirmed
      ),
    onSuccess: onChanged
  })

  function changePolicy(capability: string, policy: keyof typeof POLICY_RANK) {
    const current = (coworker.grants.find((grant) => grant.capability === capability)?.approval_policy || "off") as keyof typeof POLICY_RANK
    const escalation = POLICY_RANK[policy] > POLICY_RANK[current]
    if (escalation && !window.confirm(t("capabilities.confirm_escalation"))) return
    mutation.mutate({ capability, policy, confirmed: escalation })
  }

  function saveFileConstraints(grant: CoworkerDetail["grants"][number]) {
    const nextPaths = new Set(
      paths
        .split(",")
        .map((path) => path.trim())
        .filter(Boolean)
    )
    const removesProtection = (grant.constraints.confirm_paths || []).some((path) => !nextPaths.has(path))
    if (removesProtection && !window.confirm(t("capabilities.confirm_escalation"))) return
    mutation.mutate({ capability: grant.capability, policy: grant.approval_policy, confirmed: removesProtection })
  }

  return (
    <section className="space-y-5">
      <div className="divide-y divide-border rounded border border-border bg-surface">
        {(coworker.grant_catalog || []).map((descriptor) => {
          const capability = descriptor.name
          const grant = coworker.grants.find((entry) => entry.capability === capability)
          return (
            <div className="space-y-3 p-4 sm:flex sm:items-start sm:justify-between sm:gap-4 sm:space-y-0" key={capability}>
              <div>
                <p className="text-sm font-medium">{descriptor.label}</p>
                <p className="text-xs text-text-secondary">{descriptor.description}</p>
                {capability === "workspace.files" ? (
                  <div>
                    <label className="mt-2 block text-xs text-text-secondary">
                      {t("capabilities.confirm_paths")}
                      <Input
                        className="mt-1"
                        onChange={(event) => setPaths(event.target.value)}
                        placeholder={t("capabilities.confirm_paths_placeholder")}
                        value={paths}
                      />
                    </label>
                    <button
                      className="mt-2 rounded border border-border px-2 py-1 text-xs disabled:opacity-50"
                      disabled={!grant || mutation.isPending}
                      onClick={() => grant && saveFileConstraints(grant)}
                      type="button"
                    >
                      {t("capabilities.save_constraints")}
                    </button>
                  </div>
                ) : null}
              </div>
              <Select
                aria-label={t("capabilities.policy_for", { capability })}
                disabled={mutation.isPending}
                onChange={(event) => changePolicy(capability, event.target.value as keyof typeof POLICY_RANK)}
                value={grant?.approval_policy || "off"}
              >
                {(["auto", "confirm", "queue", "off"] as const).filter((policy) => POLICY_RANK[policy] <= POLICY_RANK[descriptor.maximum_policy]).map((policy) => (
                  <option key={policy} value={policy}>
                    {t(`capabilities.policies.${policy}`)}
                  </option>
                ))}
              </Select>
            </div>
          )
        })}
      </div>
      {mutation.isError ? <PanelMessage>{mutation.error.message}</PanelMessage> : null}
      <div className="grid gap-3 sm:grid-cols-2">
        {(["gmail", "calendar"] as const).map((integration) => (
          <div aria-disabled="true" className="rounded border border-border bg-surface-subtle p-4 opacity-60" key={integration}>
            <div className="font-medium">{t(`capabilities.integrations.${integration}`)}</div>
            <div className="text-sm text-text-secondary">{t("capabilities.coming_later")}</div>
          </div>
        ))}
      </div>
    </section>
  )
}

function CoworkerSchedules({ coworker, onChanged }: { coworker: CoworkerDetail; onChanged: () => void }) {
  const { t } = useT("coworkers")
  const [kind, setKind] = useState("cron")
  const create = useMutation({
    mutationFn: (schedule: { name: string; prompt: string; kind: string; schedule_input?: string; fire_at?: string }) =>
      createCoworkerSchedule(String(coworker.id), schedule),
    onSuccess: onChanged
  })
  const command = useMutation({
    mutationFn: ({ id, action }: { id: number; action: "pause" | "resume" | "fire_now" }) => commandCoworkerSchedule(String(coworker.id), id, action),
    onSuccess: onChanged
  })
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = new FormData(event.currentTarget)
    create.mutate({
      name: String(data.get("name") || ""),
      prompt: String(data.get("prompt") || ""),
      kind,
      schedule_input: kind === "cron" ? String(data.get("schedule_input") || "") : undefined,
      fire_at: kind === "one_shot" ? new Date(String(data.get("fire_at") || "")).toISOString() : undefined
    })
  }
  return (
    <section className="space-y-5">
      <form className="space-y-3 rounded border border-border bg-surface p-5" onSubmit={submit}>
        <h2 className="font-semibold">{t("schedule.add")}</h2>
        <Field label={t("schedule.name")} name="name" required />
        <label className="block text-sm font-medium">
          {t("schedule.kind")}
          <Select className="mt-1" onChange={(event) => setKind(event.target.value)} value={kind}>
            <option value="cron">{t("schedule.recurring")}</option>
            <option value="one_shot">{t("schedule.one_shot")}</option>
          </Select>
        </label>
        {kind === "cron" ? (
          <Field label={t("schedule.cadence")} name="schedule_input" placeholder={t("schedule.cadence_placeholder")} required />
        ) : (
          <Field label={t("schedule.fire_at")} name="fire_at" required type="datetime-local" />
        )}
        <label className="block text-sm font-medium">
          {t("schedule.prompt")}
          <Textarea className="mt-1 min-h-24" name="prompt" required />
        </label>
        {create.isError ? <PanelMessage>{create.error.message}</PanelMessage> : null}
        <button className="rounded bg-brand px-3 py-2 text-sm font-medium text-white" disabled={create.isPending}>
          {t("schedule.add")}
        </button>
      </form>
      {coworker.schedules.length === 0 ? (
        <PanelMessage>{t("schedule.empty")}</PanelMessage>
      ) : (
        <ul className="divide-y divide-border rounded border border-border bg-surface">
          {coworker.schedules.map((schedule) => (
            <li className="flex flex-wrap items-center justify-between gap-3 p-4" key={schedule.id}>
              <div>
                <div className="font-medium">{schedule.name}</div>
                <div className="text-sm text-text-secondary">
                  {schedule.schedule_explanation || schedule.fire_at} · {schedule.state}
                </div>
              </div>
              <div className="flex gap-2">
                {schedule.state === "scheduled" ? (
                  <button
                    className="rounded border border-border px-3 py-1.5 text-sm"
                    disabled={command.isPending}
                    onClick={() => command.mutate({ id: schedule.id, action: "pause" })}
                  >
                    {t("schedule.pause")}
                  </button>
                ) : null}
                {["paused", "auto_paused"].includes(schedule.state) ? (
                  <button
                    className="rounded border border-border px-3 py-1.5 text-sm"
                    disabled={command.isPending}
                    onClick={() => command.mutate({ id: schedule.id, action: "resume" })}
                  >
                    {t("schedule.resume")}
                  </button>
                ) : null}
                {schedule.state !== "fired" ? (
                  <button
                    className="rounded border border-border px-3 py-1.5 text-sm"
                    disabled={command.isPending}
                    onClick={() => command.mutate({ id: schedule.id, action: "fire_now" })}
                  >
                    {t("schedule.run_now")}
                  </button>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function CoworkerActivity({ id, traffic }: { id: string; traffic: CoworkerDetail["message_traffic"] }) {
  const { t } = useT("coworkers")
  const query = useQuery({ queryKey: ["coworkers", id, "activity"], queryFn: () => fetchCoworkerActivity(id) })
  if (query.isPending) return <PanelMessage>{t("activity.loading")}</PanelMessage>
  if (query.isError || !query.data) return <PanelMessage>{t("activity.unavailable")}</PanelMessage>
  const activity = query.data
  return (
    <section className="space-y-6 rounded border border-border bg-surface p-5">
      <div>
        <h2 className="font-semibold">{t("activity.spend")}</h2>
        <dl className="mt-3 grid gap-3 sm:grid-cols-2">
          <div className="rounded bg-surface-subtle p-3">
            <dt className="text-sm text-text-secondary">{t("activity.this_week")}</dt>
            <dd className="text-2xl font-semibold">${activity.spend.week_usd.toFixed(2)}</dd>
          </div>
          <div className="rounded bg-surface-subtle p-3">
            <dt className="text-sm text-text-secondary">{t("activity.total")}</dt>
            <dd className="text-2xl font-semibold">${activity.spend.total_usd.toFixed(2)}</dd>
            <dd className="mt-1 text-xs text-text-secondary">{t("activity.spend_not_capped")}</dd>
          </div>
        </dl>
      </div>
      <div>
        <h2 className="font-semibold">{t("activity.runs")}</h2>
        {activity.runs.length ? (
          <ul className="mt-3 divide-y divide-border rounded border border-border">
            {activity.runs.map((run) => (
              <li className="grid gap-2 p-3 text-sm sm:grid-cols-4" key={run.id}>
                <span>{t("activity.run_label", { id: run.id })}</span>
                <span>{t(`activity.status.${run.state}`, { defaultValue: run.state })}</span>
                <span>{t("activity.tool_calls", { count: run.tool_calls_count })}</span>
                <span className="sm:text-right">${run.cost_usd.toFixed(2)}</span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-sm text-text-secondary">{t("activity.no_runs")}</p>
        )}
      </div>
      <div>
        <h2 className="font-semibold">{t("activity.side_chats")}</h2>
        {activity.side_chats.length ? (
          <ul className="mt-3 space-y-2">
            {activity.side_chats.map((chat) => (
              <li className="flex justify-between rounded border border-border p-3 text-sm" key={chat.id}>
                <Link className="text-brand" to={chat.path}>
                  {chat.title || t("activity.untitled_chat")}
                </Link>
                <span>${chat.cost_usd.toFixed(2)}</span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-sm text-text-secondary">{t("activity.no_side_chats")}</p>
        )}
      </div>
      <div>
        <h2 className="font-semibold">{t("activity.message_traffic")}</h2>
        <p className="mt-1 text-sm text-text-secondary">{t("activity.window", { count: traffic.window_days })}</p>
        <dl className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="rounded bg-surface-subtle p-3">
            <dt className="text-sm text-text-secondary">{t("activity.sent")}</dt>
            <dd className="text-2xl font-semibold">{traffic.sent}</dd>
          </div>
          <div className="rounded bg-surface-subtle p-3">
            <dt className="text-sm text-text-secondary">{t("activity.received")}</dt>
            <dd className="text-2xl font-semibold">{traffic.received}</dd>
          </div>
        </dl>
        <h3 className="mt-6 font-semibold">{t("activity.delivery_issues")}</h3>
        {traffic.delivery_events.length ? (
          <ul className="mt-3 space-y-2">
            {traffic.delivery_events.map((event) => (
              <li className="rounded border border-border bg-surface-subtle p-3 text-sm" key={`${event.occurred_at}-${event.receiver_handle}`}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-medium">{t(`activity.${event.status}`, { handle: event.receiver_handle })}</span>
                  <time className="text-text-secondary" dateTime={event.occurred_at}>
                    {new Date(event.occurred_at).toLocaleString()}
                  </time>
                </div>
                <p className="mt-1 text-text-secondary">{event.reason}</p>
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-sm text-text-secondary">{t("activity.no_delivery_issues")}</p>
        )}
      </div>
    </section>
  )
}

function CoworkerWorkspace({ id, remote }: { id: string; remote: string }) {
  const { t } = useT("coworkers")
  const [selectedPath, setSelectedPath] = useState<string | undefined>()
  const query = useQuery({
    queryKey: ["coworkers", id, "workspace", selectedPath],
    queryFn: () => fetchCoworkerWorkspace(id, selectedPath)
  })
  const pushTest = useMutation({ mutationFn: () => testCoworkerRemote(remote) })

  if (query.isPending) return <PanelMessage>{t("workspace.loading")}</PanelMessage>
  if (query.isError || !query.data) return <PanelMessage>{t("workspace.unavailable")}</PanelMessage>
  const workspace = query.data
  return (
    <section className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3 rounded border border-border bg-surface p-3 text-sm">
        <div>
          <div className="font-medium text-text-primary">{workspace.remote}</div>
          <div className="text-text-muted">{workspace.branch}</div>
        </div>
        <div>
          <button className="rounded border border-border px-3 py-2" disabled={pushTest.isPending} onClick={() => pushTest.mutate()} type="button">
            {t("workspace.test_push")}
          </button>
          {pushTest.isSuccess ? <span className="ml-2 text-success">{t("workspace.push_ok")}</span> : null}
          {pushTest.isError ? <span className="ml-2 text-danger">{pushTest.error.message}</span> : null}
        </div>
      </div>
      {workspace.partial ? <PanelMessage>{t("workspace.partial")}</PanelMessage> : null}
      {workspace.conflicts.map((conflict) => (
        <PanelMessage key={conflict.branch}>
          {t("workspace.conflict", { branch: conflict.branch })} {conflict.files.join(", ")}
        </PanelMessage>
      ))}
      <div className="grid min-h-96 overflow-hidden rounded border border-border bg-surface md:grid-cols-[18rem_minmax(0,1fr)]">
        <nav aria-label={t("workspace.files")} className="border-b border-border p-3 md:border-b-0 md:border-r">
          {workspace.files
            .filter((file) => file.type !== "directory")
            .map((file) => (
              <button
                className="block w-full rounded px-2 py-1.5 text-left text-sm hover:bg-surface-subtle"
                key={file.path}
                onClick={() => setSelectedPath(file.path)}
                type="button"
              >
                {file.path}
              </button>
            ))}
        </nav>
        <article className="min-w-0 p-5">
          {workspace.selected_file ? (
            <>
              <h2 className="mb-3 font-semibold">{workspace.selected_file.path}</h2>
              {workspace.selected_file.truncated ? <PanelMessage>{t("workspace.truncated")}</PanelMessage> : null}
              {workspace.selected_file.binary ? (
                <PanelMessage>{t("workspace.binary")}</PanelMessage>
              ) : workspace.selected_file.path.toLowerCase().endsWith(".md") ? (
                <Markdown className="chat-prose text-sm" text={workspace.selected_file.content} />
              ) : (
                <pre className="overflow-auto whitespace-pre-wrap text-sm">{workspace.selected_file.content}</pre>
              )}
            </>
          ) : (
            <PanelMessage>{t("workspace.choose_file")}</PanelMessage>
          )}
        </article>
      </div>
      <div className="rounded border border-border bg-surface p-4">
        <h2 className="mb-3 font-semibold">{t("workspace.history")}</h2>
        {workspace.commits.length === 0 ? <p className="text-sm text-text-muted">{t("workspace.no_commits")}</p> : null}
        <ol className="space-y-2">
          {workspace.commits.map((commit) => (
            <li className="text-sm" key={commit.sha}>
              <code>{commit.sha.slice(0, 7)}</code> {commit.message}
              <span className="ml-2 text-text-muted">{t(`workspace.${commit.source}_source`, { id: commit.source_id })}</span>
            </li>
          ))}
        </ol>
      </div>
    </section>
  )
}

const memoryFilterSchema = (label: string) => [{ field: "search", label, bucket: "text", operators: ["contains"], values: [], free_text_search: true }]

function memoryFilterTree(search: string): FilterTree {
  const value = new URLSearchParams(search).get("search")?.trim()
  return { and: value ? [{ field: "search", op: "contains", value }] : [] }
}

const memoryFilterLink: FilterLinkBuilder = (path, search, updates) => {
  const params = new URLSearchParams(search)
  if (typeof updates.q === "string" && updates.q) {
    try {
      const encoded = updates.q.replace(/-/g, "+").replace(/_/g, "/")
      const tree = JSON.parse(atob(encoded)) as { and?: Array<{ field?: string; value?: unknown }> }
      const value = tree.and?.find((chip) => chip.field === "search")?.value
      if (typeof value === "string" && value.trim()) params.set("search", value.trim())
      else params.delete("search")
    } catch {
      params.delete("search")
    }
  } else if (updates.q == null) params.delete("search")
  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function CoworkerMemory({ id }: { id: string }) {
  const { t } = useT("coworkers")
  const location = useLocation()
  const prefix = usePrefix()
  const searchValue = new URLSearchParams(location.search).get("search")?.trim() || ""
  const queryString = searchValue ? `?search=${encodeURIComponent(searchValue)}` : ""
  const query = useQuery({ queryKey: ["coworkers", id, "memory", searchValue], queryFn: () => fetchCoworkerMemory(id, queryString) })
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const files = query.data?.files || []
  const selected = files.find((file) => file.path === selectedPath) || files[0]

  useEffect(() => {
    if (files.length > 0 && !files.some((file) => file.path === selectedPath)) setSelectedPath(files[0].path)
  }, [files, selectedPath])

  return (
    <section className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <FilterBar
          buildLink={memoryFilterLink}
          filter={memoryFilterTree(location.search)}
          filterSchema={memoryFilterSchema(t("memory.search"))}
          legacyFilterKeys={["search"]}
          pathname={location.pathname}
          search={location.search}
        />
        <Link className="shrink-0 text-sm text-brand underline" to={`${prefix}/memories`}>
          {t("memory.owner_memories")}
        </Link>
      </div>
      {query.isPending ? <PanelMessage>{t("memory.loading")}</PanelMessage> : null}
      {query.isError ? <PanelMessage>{t("memory.unavailable")}</PanelMessage> : null}
      {query.data?.search_incomplete ? <PanelMessage>{t("memory.search_incomplete")}</PanelMessage> : null}
      {query.data?.partial && !query.data.search_incomplete ? <PanelMessage>{t("memory.partial")}</PanelMessage> : null}
      {query.isSuccess && files.length === 0 && !query.data.search_incomplete ? (
        <PanelMessage>{searchValue ? t("memory.no_results") : t("memory.empty")}</PanelMessage>
      ) : null}
      {query.isSuccess && files.length > 0 ? (
        <div className="grid min-h-96 overflow-hidden rounded border border-border bg-surface md:grid-cols-[15rem_minmax(0,1fr)]">
          <MemoryFileList files={files} selectedPath={selected?.path} setSelectedPath={setSelectedPath} />
          <article className="min-w-0 border-t border-border p-5 md:border-l md:border-t-0">
            <div className="mb-4 border-b border-border pb-3">
              <h2 className="font-semibold text-text-primary">{selected?.name}</h2>
              <p className="text-xs text-text-muted">{selected?.path}</p>
            </div>
            {selected?.truncated ? <p className="mb-3 text-sm text-warning">{t("memory.truncated")}</p> : null}
            <Markdown className="chat-prose text-sm text-text-primary" text={selected?.content || ""} />
          </article>
        </div>
      ) : null}
    </section>
  )
}

function MemoryFileList({
  files,
  selectedPath,
  setSelectedPath
}: {
  files: CoworkerMemoryFile[]
  selectedPath?: string
  setSelectedPath: (path: string) => void
}) {
  const { t } = useT("coworkers")
  const categories = ["daily", "people", "repos", "banks"] as const
  return (
    <nav aria-label={t("memory.files")} className="p-3">
      {categories.map((category) => {
        const categoryFiles = files.filter((file) => file.category === category)
        if (categoryFiles.length === 0) return null
        return (
          <div className="mb-4" key={category}>
            <h3 className="mb-1 px-2 text-xs font-semibold uppercase tracking-wide text-text-muted">{t(`memory.categories.${category}`)}</h3>
            {categoryFiles.map((file) => (
              <button
                className={`block w-full rounded px-2 py-1.5 text-left text-sm ${selectedPath === file.path ? "bg-brand-soft text-brand" : "text-text-secondary hover:bg-surface-subtle"}`}
                key={file.path}
                onClick={() => setSelectedPath(file.path)}
                type="button"
              >
                {file.name}
              </button>
            ))}
          </div>
        )
      })}
    </nav>
  )
}

function Tabs({ active, setActive, labels }: { active: string; setActive: (value: string) => void; labels: string[] }) {
  const { t } = useT("coworkers")
  return (
    <div className="mb-5 flex gap-5 overflow-x-auto border-b border-border">
      {labels.map((label) => (
        <button
          className={`pb-2 text-sm ${active === label ? "border-b-2 border-brand font-semibold" : "text-text-secondary"}`}
          key={label}
          onClick={() => setActive(label)}
        >
          {t(`tabs.${label}`)}
        </button>
      ))}
    </div>
  )
}
function SyrusPage({ tab, setTab }: { tab: string; setTab: (value: string) => void }) {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header>
        <PageHeading>Syrus</PageHeading>
        <p className="text-text-secondary">{t("built_in")}</p>
      </Page.Header>
      <Tabs active={tab} setActive={setTab} labels={["chats", "profile", "capabilities", "schedule", "memory"]} />
      {tab === "profile" ? (
        <PanelMessage>{t("detail.account_default")}</PanelMessage>
      ) : tab === "capabilities" ? (
        <PanelMessage>{t("detail.engineer_capabilities")}</PanelMessage>
      ) : tab === "chats" ? (
        <Link className="text-brand underline" to={`${prefix}/chats/search`}>
          {t("tabs.chats")}
        </Link>
      ) : tab === "schedule" ? (
        <Link className="text-brand underline" to={`${prefix}/scheduled_tasks`}>
          {t("tabs.schedule")}
        </Link>
      ) : tab === "memory" ? (
        <Link className="text-brand underline" to={`${prefix}/memories`}>
          {t("tabs.memory")}
        </Link>
      ) : (
        <PanelMessage>{t("detail.existing_link")}</PanelMessage>
      )}
    </Page.Root>
  )
}
