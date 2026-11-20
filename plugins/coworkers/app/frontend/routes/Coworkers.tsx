import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { FormEvent, type KeyboardEvent, type ReactNode, useEffect, useMemo, useRef, useState } from "react"
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
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { ToolApprovalDetails } from "@app/components/ToolApprovalDetails"
import { FilterBar, type FilterLinkBuilder, type FilterTree } from "@app/components/FilterBar"
import { encodeFilterTree } from "@app/components/filterBar/helpers"
import { Page } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { Markdown } from "@app/lib/Markdown"
import { withRoutePrefix } from "@app/lib/routing"
import { defaultAccentSelection, resolveAccentSelection, type AccentSelection } from "@app/lib/appearance"
import {
  commandCoworkerSchedule,
  createCoworkerSchedule,
  updateCoworkerSchedule,
  createCoworker,
  createSideChat,
  fetchCoworker,
  fetchCoworkerConversationIndex,
  renameCoworkerConversation,
  archiveCoworkerConversation,
  deleteCoworkerConversation,
  fetchCoworkerOptions,
  fetchCoworkerTab,
  fetchCoworkerActivity,
  fetchCoworkerApprovals,
  fetchCoworkerWorkspace,
  fetchCoworkers,
  retryCoworkerWorkspaceSave,
  retryProvisioningCleanup,
  acknowledgeProvisioningCleanup,
  decideCoworkerApproval,
  testCoworkerRemote,
  updateCoworker,
  updateCoworkerGrant,
  type CoworkerDetail,
  type CoworkerConversation,
  type CoworkerSchedule,
  type CoworkerWorkspacePayload,
  type CoworkerSummary
} from "../api/coworkers"

export default function CoworkersRoute() {
  const { id } = useParams()
  const location = useLocation()
  if (location.pathname.endsWith("/new")) return <NewCoworker />
  if (id && location.pathname.endsWith("/edit")) return <EditCoworker id={id} />
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
  const optionsQuery = useQuery({ queryKey: ["coworkers", "options"], queryFn: fetchCoworkerOptions })
  const mutation = useMutation({ mutationFn: createCoworker, onSuccess: (data) => navigate(withRoutePrefix(data.redirect_to, prefix)) })
  const remoteTest = useMutation({ mutationFn: () => testCoworkerRemote(remote) })
  useEffect(() => {
    if (optionsQuery.data && !colorEdited) setColor(defaultAccentSelection(optionsQuery.data.accent_hexes))
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
            <div className="mb-3" key={grant.name}>
              <Checkbox
                defaultChecked={grant.default_enabled}
                disabled={grant.scopeable && !grant.scope_options?.length}
                label={grant.label}
                name="grants[]"
                value={grant.name}
              />
              {grant.scopeable && grant.scope_options?.length ? (
                <label className="ml-6 mt-1 block text-xs text-text-secondary">
                  {t("capabilities.scope_for", { capability: grant.label })}
                  <Select className="mt-1" defaultValue={JSON.stringify(grant.scope_options[0].value)} name={`grant_scopes[${grant.name}]`}>
                    {grant.scope_options.map((option) => (
                      <option key={JSON.stringify(option.value)} value={JSON.stringify(option.value)}>
                        {option.label}
                      </option>
                    ))}
                  </Select>
                </label>
              ) : null}
            </div>
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

function Field({
  label,
  ...props
}: {
  label: string
  name: string
  required?: boolean
  pattern?: string
  type?: string
  placeholder?: string
  defaultValue?: string
}) {
  return (
    <label className="block text-sm font-medium">
      {label}
      <Input {...props} className="mt-1" />
    </label>
  )
}

function EditCoworker({ id }: { id: string }) {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const query = useQuery({ queryKey: ["coworkers", id], queryFn: () => fetchCoworker(id) })
  const options = useQuery({ queryKey: ["coworkers", "options"], queryFn: fetchCoworkerOptions })
  const [avatar, setAvatar] = useState<string | null>(null)
  const [color, setColor] = useState<AccentSelection>(() => defaultAccentSelection())
  const [colorPopupOpen, setColorPopupOpen] = useState(false)
  const mutation = useMutation({
    mutationFn: (attributes: Record<string, string | null>) => updateCoworker(id, attributes),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["coworkers"] })
      navigate(`${prefix}/coworkers/${id}`)
    }
  })

  useEffect(() => {
    const coworker = query.data?.coworker
    if (!coworker) return
    setAvatar(coworker.avatar_key)
    setColor(resolveAccentSelection(coworker.accent_hex))
  }, [query.data])

  if (query.isPending) return <PanelMessage>{t("loading")}</PanelMessage>
  if (!query.data) return <PanelMessage>{t("error")}</PanelMessage>
  const coworker = query.data.coworker
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (mutation.isPending) return
    const form = new FormData(event.currentTarget)
    const model = form.get("model")?.toString() || ""
    const [chatProvider, chatModel] = model ? model.split(":", 2) : ["", ""]
    mutation.mutate({
      name: form.get("name")?.toString() || "",
      handle: form.get("handle")?.toString() || "",
      about: form.get("about")?.toString() || "",
      accent_hex: color.accentHex,
      avatar_key: avatar,
      chat_provider: chatProvider || null,
      chat_model: chatModel || null
    })
  }
  const selectedModel = coworker.chat_provider && coworker.chat_model ? `${coworker.chat_provider}:${coworker.chat_model}` : ""
  return (
    <Page.Root gutter="responsive" size="narrow">
      <Page.Header>
        <Link className="text-sm text-brand" to={`${prefix}/coworkers/${id}`}>
          {coworker.name}
        </Link>
        <PageHeading>{t("edit.title")}</PageHeading>
      </Page.Header>
      <form className="space-y-5 rounded border border-border bg-surface p-5" onSubmit={submit}>
        <Field defaultValue={coworker.name} label={t("fields.name")} name="name" required />
        <Field defaultValue={coworker.handle} label={t("fields.handle")} name="handle" pattern="[a-z0-9_-]{3,32}" required />
        <label className="block text-sm font-medium">
          {t("fields.model")}
          <Select className="mt-1" defaultValue={selectedModel} name="model">
            <option value="">{t("detail.account_default")}</option>
            {(options.data?.model_options || []).map((provider) => (
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
          <Input className="mt-1" disabled value={coworker.workspace_repo} />
        </label>
        <div className="relative">
          <label className="mb-2 block text-sm font-medium">{t("fields.color")}</label>
          <button
            aria-expanded={colorPopupOpen}
            aria-haspopup="dialog"
            className="flex items-center gap-2 rounded border border-border px-3 py-2 text-sm"
            onClick={() => setColorPopupOpen((open) => !open)}
            type="button"
          >
            <span className="h-5 w-5 rounded-full border border-border" style={{ backgroundColor: color.accentHex }} />
            {color.accentHex}
          </button>
          {colorPopupOpen ? (
            <div
              aria-label={t("fields.color")}
              className="absolute z-20 mt-2 w-[min(90vw,36rem)] rounded border border-border bg-surface p-3 shadow-lg"
              role="dialog"
            >
              <ColorPicker
                accentRef={color.accentRef}
                ariaLabel={t("fields.color")}
                mode="light"
                name={coworker.name}
                onChange={setColor}
                value={color.accentHex}
              />
            </div>
          ) : null}
        </div>
        <div>
          <label className="mb-2 block text-sm font-medium">{t("fields.avatar")}</label>
          <AvatarPicker ariaLabel={t("fields.avatar")} onChange={setAvatar} value={avatar} />
        </div>
        <label className="block text-sm font-medium">
          {t("fields.about")}
          <Textarea className="mt-1 min-h-28" defaultValue={coworker.about || ""} name="about" />
        </label>
        {mutation.isError ? <PanelMessage>{mutation.error.message}</PanelMessage> : null}
        <button className="rounded bg-brand px-4 py-2 font-medium text-white disabled:opacity-60" disabled={mutation.isPending}>
          {mutation.isPending ? t("edit.saving") : t("edit.save")}
        </button>
      </form>
    </Page.Root>
  )
}

function CoworkerPage({ id }: { id: string }) {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const requestedTab = new URLSearchParams(location.search).get("tab")
  const legacyTab = requestedTab === "profile" || requestedTab === "memory" ? "workspace" : requestedTab
  const [tab, setTab] = useState(id === "syrus" ? "chats" : legacyTab || "chat")
  useEffect(() => {
    if (requestedTab !== "profile" && requestedTab !== "memory") return
    const params = new URLSearchParams(location.search)
    params.set("tab", "workspace")
    if (requestedTab === "profile") params.set("path", "SOUL.md")
    if (requestedTab === "memory") params.set("path_prefix", "memory")
    navigate({ search: `?${params}` }, { replace: true })
  }, [location.search, navigate, requestedTab])
  const query = useQuery({ queryKey: ["coworkers", id], queryFn: () => fetchCoworker(id), enabled: id !== "syrus" })
  const detailTab = ({ chat: "chats", capabilities: "capabilities", schedule: "schedules" } as const)[
    tab as "chat" | "capabilities" | "schedule"
  ]
  const tabQuery = useQuery({
    queryKey: ["coworkers", id, detailTab],
    queryFn: () => fetchCoworkerTab(id, detailTab!),
    enabled: id !== "syrus" && Boolean(detailTab)
  })
  const sideChat = useMutation({
    mutationFn: () => createSideChat(Number(id)),
    onSuccess: async (data) => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["coworkers", id, "chats"] }),
        queryClient.invalidateQueries({ queryKey: ["coworkers", id, "conversation-index"] }),
        queryClient.invalidateQueries({ queryKey: ["chats"] })
      ])
      navigate(withRoutePrefix(data.chat_path, prefix))
    }
  })
  if (id === "syrus") return <SyrusPage tab={tab} setTab={setTab} />
  if (query.isPending) return <PanelMessage>{t("loading")}</PanelMessage>
  if (!query.data) return <PanelMessage>{t("error")}</PanelMessage>
  if (detailTab && tabQuery.isPending) return <PanelMessage>{t("loading")}</PanelMessage>
  const coworker = { ...query.data.coworker, ...tabQuery.data } as CoworkerDetail
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
          <Link className="ml-auto rounded border border-border px-3 py-2 text-sm" to={`${prefix}/coworkers/${id}/edit`}>
            {t("detail.edit")}
          </Link>
        </div>
      </Page.Header>
      <Tabs active={tab} setActive={setTab} labels={["chat", "capabilities", "approvals", "schedule", "workspace", "activity"]} />
      {tab === "chat" ? <CoworkerConversationIndex id={id} create={sideChat} legacyChats={coworker.chats} prefix={prefix} /> : null}
      {tab === "capabilities" ? <CoworkerCapabilities coworker={coworker} onChanged={() => void tabQuery.refetch()} /> : null}
      {tab === "approvals" ? <CoworkerApprovals id={id} /> : null}
      {tab === "schedule" ? <CoworkerSchedules coworker={coworker} onChanged={() => void tabQuery.refetch()} /> : null}
      {tab === "workspace" ? <CoworkerWorkspace id={id} remote={coworker.workspace_repo} /> : null}
      {tab === "activity" ? <CoworkerActivity id={id} /> : null}
      {!["chat", "capabilities", "approvals", "schedule", "workspace", "activity"].includes(tab) ? (
        <PanelMessage>{t("coming_later")}</PanelMessage>
      ) : null}
    </Page.Root>
  )
}

function CoworkerConversationIndex({
  id,
  prefix,
  create,
  legacyChats
}: {
  id: string
  prefix: string
  create: { isPending: boolean; isError: boolean; error: Error | null; mutate: () => void }
  legacyChats: CoworkerDetail["chats"]
}) {
  const { t } = useT("coworkers")
  const location = useLocation()
  const navigate = useNavigate()
  const querySearch = useMemo(() => {
    const params = new URLSearchParams(location.search)
    params.delete("tab")
    const value = params.toString()
    return value ? `?${value}` : ""
  }, [location.search])
  const query = useQuery({
    queryKey: ["coworkers", id, "conversation-index", querySearch],
    queryFn: () => fetchCoworkerConversationIndex(id, querySearch),
    placeholderData: (previous) => previous
  })
  const [older, setOlder] = useState<CoworkerConversation[]>([])
  const [cursor, setCursor] = useState<string | null>(null)
  const loadMore = useMutation({
    mutationFn: () => {
      const params = new URLSearchParams(querySearch)
      if (cursor) params.set("cursor", cursor)
      return fetchCoworkerConversationIndex(id, `?${params}`)
    },
    onSuccess: (page) => {
      setOlder((current) => [...current, ...page.side_chats])
      setCursor(page.next_cursor)
    }
  })
  useEffect(() => {
    setOlder([])
    setCursor(query.data?.next_cursor || null)
  }, [query.data, querySearch])

  function setSort(event: React.ChangeEvent<HTMLSelectElement>) {
    const params = new URLSearchParams(location.search)
    if (event.target.value === "last_activity") params.delete("sort")
    else params.set("sort", event.target.value)
    params.delete("cursor")
    navigate(`${location.pathname}?${params}`)
  }

  if (query.isPending) return <PanelMessage>{t("conversations.loading")}</PanelMessage>
  if (query.isError || !query.data) return <PanelMessage>{t("conversations.error")}</PanelMessage>
  const payload = Array.isArray(query.data.side_chats) && Array.isArray(query.data.filter_schema) ? query.data : legacyConversationPayload(legacyChats)
  const sideChats = [...payload.side_chats, ...older]
  return (
    <section className="space-y-5" aria-label={t("conversations.index_label")}>
      <div className="flex items-center justify-between gap-3">
        <div>
          <h2 className="font-semibold">{t("conversations.heading")}</h2>
          <p className="text-sm text-text-secondary">{t("conversations.description")}</p>
        </div>
        <button
          className="shrink-0 rounded bg-brand px-3 py-2 text-sm text-white disabled:opacity-60"
          disabled={create.isPending}
          onClick={() => create.mutate()}
        >
          {create.isPending ? t("detail.creating_side_chat") : t("detail.new_side_chat")}
        </button>
      </div>
      {create.isError && create.error ? <PanelMessage>{create.error.message}</PanelMessage> : null}
      {payload.main_chat ? (
        <div>
          <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-text-secondary">{t("conversations.pinned")}</h3>
          <ConversationRow chat={payload.main_chat} coworkerId={id} prefix={prefix} />
        </div>
      ) : null}
      <div className="space-y-3">
        <div className="flex flex-col items-stretch gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h3 className="font-semibold">{t("activity.side_chats")}</h3>
            <p className="text-sm text-text-secondary">
              {t(payload.result_count_exact ? "conversations.result_count" : "conversations.result_count_limited", { count: payload.result_count })}
            </p>
          </div>
          <label className="w-full text-sm font-medium sm:w-auto">
            {t("conversations.sort")}
            <Select className="mt-1 max-w-full sm:ml-2 sm:mt-0" onChange={setSort} value={payload.sort}>
              <option value="last_activity">{t("conversations.sort_last_activity")}</option>
              <option value="title">{t("conversations.sort_title")}</option>
              <option value="created_at">{t("conversations.sort_created")}</option>
            </Select>
          </label>
        </div>
        <div className="rounded border border-border bg-surface p-3">
          <FilterBar filter={payload.filter} filterSchema={payload.filter_schema} pathname={location.pathname} search={location.search} />
        </div>
        {sideChats.length ? (
          <ul className="divide-y divide-border rounded border border-border bg-surface">
            {sideChats.map((chat) => (
              <li key={chat.id}>
                <ConversationRow chat={chat} coworkerId={id} prefix={prefix} />
              </li>
            ))}
          </ul>
        ) : (
          <PanelMessage>
            {payload.result_count === 0 && !hasConversationFilters(payload.filter) ? t("activity.no_side_chats") : t("conversations.no_matches")}
          </PanelMessage>
        )}
        {cursor ? (
          <button
            className="rounded border border-border px-3 py-2 text-sm disabled:opacity-60"
            disabled={loadMore.isPending}
            onClick={() => loadMore.mutate()}
          >
            {loadMore.isPending ? t("conversations.loading_more") : t("activity.load_more")}
          </button>
        ) : null}
        {loadMore.isError ? <PanelMessage>{t("conversations.error")}</PanelMessage> : null}
      </div>
    </section>
  )
}

function legacyConversationPayload(chats: CoworkerDetail["chats"]): Awaited<ReturnType<typeof fetchCoworkerConversationIndex>> {
  const row = (chat: CoworkerDetail["chats"][number]): CoworkerConversation => ({
    id: chat.id,
    title: chat.title,
    path: chat.path,
    main: chat.role === "main",
    preview: null,
    last_activity_at: "",
    created_at: "",
    archived: false,
    unread: false,
    active_work: false,
    title_match: false,
    match_count: 0,
    match: null
  })
  return {
    main_chat: chats.find((chat) => chat.role === "main") ? row(chats.find((chat) => chat.role === "main")!) : null,
    side_chats: chats.filter((chat) => chat.role === "side").map(row),
    result_count: chats.filter((chat) => chat.role === "side").length,
    result_count_exact: true,
    next_cursor: null,
    filter: { and: [] },
    filter_schema: [],
    sort: "last_activity"
  }
}

function hasConversationFilters(filter: Record<string, unknown>) {
  return Array.isArray(filter.and) && filter.and.length > 0
}

function ConversationRow({ chat, coworkerId, prefix }: { chat: CoworkerConversation; coworkerId: string; prefix: string }) {
  const { t } = useT("coworkers")
  const queryClient = useQueryClient()
  const action = useMutation({
    mutationFn: async (kind: "rename" | "archive" | "delete") => {
      if (kind === "rename") {
        const title = window.prompt(t("conversations.rename_prompt"), chat.title)?.trim()
        if (title) await renameCoworkerConversation(chat.id, title)
      } else if (kind === "archive") {
        await archiveCoworkerConversation(chat.id, chat.archived)
      } else if (window.confirm(t("conversations.delete_confirm", { title: chat.title }))) {
        await deleteCoworkerConversation(chat.id)
      }
    },
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: ["coworkers", coworkerId, "conversation-index"] })
  })
  const destination = `${withRoutePrefix(chat.path, prefix)}${chat.match ? `#message-${chat.match.message_id}` : ""}`
  return (
    <article className={`flex min-w-0 items-start gap-3 p-4 ${chat.main ? "rounded border border-brand/30 bg-brand/5" : ""}`}>
      <Link className="min-w-0 flex-1" to={destination}>
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-medium text-brand">{chat.main ? t("detail.main_chat") : chat.title_match ? <mark>{chat.title}</mark> : chat.title}</span>
          {chat.unread ? <span className="rounded-full bg-brand px-2 py-0.5 text-xs text-white">{t("conversations.unread")}</span> : null}
          {chat.active_work ? <span className="rounded-full bg-warning-subtle px-2 py-0.5 text-xs">{t("conversations.active_work")}</span> : null}
          {chat.archived ? <span className="rounded-full bg-surface-muted px-2 py-0.5 text-xs">{t("conversations.archived")}</span> : null}
          {chat.match_count > 0 ? <span className="text-xs text-text-secondary">{t("conversations.matches", { count: chat.match_count })}</span> : null}
        </div>
        {chat.match ? (
          <p className="mt-1 line-clamp-2 text-sm text-text-secondary" dangerouslySetInnerHTML={{ __html: safeMatchSnippet(chat.match.snippet) }} />
        ) : chat.preview ? (
          <p className="mt-1 line-clamp-2 text-sm text-text-secondary">{chat.preview}</p>
        ) : null}
        {chat.last_activity_at ? <RelativeTimestamp value={chat.last_activity_at} /> : null}
      </Link>
      {!chat.main ? (
        <details className="relative shrink-0">
          <summary aria-label={t("conversations.actions", { title: chat.title })} className="cursor-pointer list-none rounded px-2 py-1 text-text-secondary">
            •••
          </summary>
          <div className="absolute right-0 z-10 mt-1 min-w-32 rounded border border-border bg-surface p-1 shadow-lg">
            <button
              className="block w-full rounded px-3 py-2 text-left text-sm hover:bg-surface-muted"
              disabled={action.isPending}
              onClick={() => action.mutate("rename")}
            >
              {t("conversations.rename")}
            </button>
            <button
              className="block w-full rounded px-3 py-2 text-left text-sm hover:bg-surface-muted"
              disabled={action.isPending}
              onClick={() => action.mutate("archive")}
            >
              {t(chat.archived ? "conversations.restore" : "conversations.archive")}
            </button>
            <button
              className="block w-full rounded px-3 py-2 text-left text-sm text-danger-text hover:bg-surface-muted"
              disabled={action.isPending}
              onClick={() => action.mutate("delete")}
            >
              {t("conversations.delete")}
            </button>
          </div>
        </details>
      ) : null}
    </article>
  )
}

function safeMatchSnippet(html: string) {
  const template = document.createElement("template")
  template.innerHTML = html
  const output = document.createElement("span")
  const clean = (node: Node, parent: Node) => {
    if (node.nodeType === Node.TEXT_NODE) return parent.appendChild(document.createTextNode(node.textContent || ""))
    if (node instanceof HTMLElement && node.tagName.toLowerCase() === "mark") {
      const mark = document.createElement("mark")
      node.childNodes.forEach((child) => clean(child, mark))
      return parent.appendChild(mark)
    }
    node.childNodes.forEach((child) => clean(child, parent))
  }
  template.content.childNodes.forEach((child) => clean(child, output))
  return output.innerHTML
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
          <ToolApprovalDetails actor={approval.actor} args={approval.tool_input} toolName={approval.tool_name} />
          <div className="mt-1 text-sm text-text-secondary">
            {approval.run_id ? t("approvals.run", { id: approval.run_id }) : t("approvals.chat", { id: approval.chat_id })}
          </div>
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
const SPAWN_CAPABILITIES = new Set(["coworker.spawn_chat", "syrus.spawn_chat"])
const DEFAULT_SPAWN_CAPS = { max_spawns_per_run: 3, max_spawns_per_day: 10 }

function CoworkerCapabilities({ coworker, onChanged }: { coworker: CoworkerDetail; onChanged: () => void }) {
  const { t } = useT("coworkers")
  const [paths, setPaths] = useState(coworker.grants.find((grant) => grant.capability === "workspace.files")?.constraints.confirm_paths?.join(", ") || "")
  const [spawnCaps, setSpawnCaps] = useState<Record<string, typeof DEFAULT_SPAWN_CAPS>>(() =>
    Object.fromEntries(
      coworker.grants
        .filter((grant) => SPAWN_CAPABILITIES.has(grant.capability))
        .map((grant) => [
          grant.capability,
          {
            max_spawns_per_run: grant.constraints.max_spawns_per_run || DEFAULT_SPAWN_CAPS.max_spawns_per_run,
            max_spawns_per_day: grant.constraints.max_spawns_per_day || DEFAULT_SPAWN_CAPS.max_spawns_per_day
          }
        ])
    )
  )
  const [scopes, setScopes] = useState<Record<string, unknown>>(() => Object.fromEntries(coworker.grants.map((grant) => [grant.capability, grant.scope])))
  const mutation = useMutation({
    mutationFn: ({ capability, policy, confirmed, scope }: { capability: string; policy: string; confirmed: boolean; scope?: unknown }) =>
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
          : SPAWN_CAPABILITIES.has(capability)
            ? spawnCaps[capability] || DEFAULT_SPAWN_CAPS
            : {},
        confirmed,
        scope
      ),
    onSuccess: onChanged
  })

  function changePolicy(capability: string, policy: keyof typeof POLICY_RANK) {
    const current = (coworker.grants.find((grant) => grant.capability === capability)?.approval_policy || "off") as keyof typeof POLICY_RANK
    const descriptor = coworker.grant_catalog.find((entry) => entry.name === capability)
    const scope = scopes[capability] ?? descriptor?.scope_options?.[0]?.value
    const escalation = POLICY_RANK[policy] > POLICY_RANK[current]
    if (escalation && !window.confirm(t("capabilities.confirm_escalation"))) return
    mutation.mutate({ capability, policy, confirmed: escalation, scope })
  }

  function changeScope(capability: string, encodedScope: string) {
    const scope = JSON.parse(encodedScope) as unknown
    const grant = coworker.grants.find((entry) => entry.capability === capability)
    setScopes((current) => ({ ...current, [capability]: scope }))
    if (!grant || JSON.stringify(grant.scope) === JSON.stringify(scope)) return
    if (!window.confirm(t("capabilities.confirm_escalation"))) return
    mutation.mutate({ capability, policy: grant.approval_policy, confirmed: true, scope })
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

  function saveSpawnCaps(grant: CoworkerDetail["grants"][number]) {
    const next = spawnCaps[grant.capability] || DEFAULT_SPAWN_CAPS
    const escalation =
      next.max_spawns_per_run > (grant.constraints.max_spawns_per_run ?? DEFAULT_SPAWN_CAPS.max_spawns_per_run) ||
      next.max_spawns_per_day > (grant.constraints.max_spawns_per_day ?? DEFAULT_SPAWN_CAPS.max_spawns_per_day)
    if (escalation && !window.confirm(t("capabilities.confirm_escalation"))) return
    mutation.mutate({ capability: grant.capability, policy: grant.approval_policy, confirmed: escalation })
  }

  return (
    <section className="space-y-5">
      <div className="divide-y divide-border rounded border border-border bg-surface">
        {coworker.grant_catalog.map((descriptor) => {
          const capability = descriptor.name
          const grant = coworker.grants.find((entry) => entry.capability === capability)
          return (
            <div className="space-y-3 p-4 sm:flex sm:items-start sm:justify-between sm:gap-4 sm:space-y-0" key={capability}>
              <div>
                <p className="text-sm font-medium">{descriptor.label}</p>
                <p className="text-sm">{t(`capabilities.sentences.${capability.replaceAll(".", "_")}`, { defaultValue: descriptor.description })}</p>
                <p className="mt-1 text-xs text-text-secondary">
                  {t("capabilities.unlocks", { tools: descriptor.tools.join(", ") || t("capabilities.no_tools") })}
                </p>
                {descriptor.available === false ? (
                  <p className="mt-2 rounded border border-warning-border bg-warning-bg px-2 py-1 text-xs text-warning-text">
                    {t(`capabilities.unavailable.${descriptor.unavailable_reason || "confinement_unavailable"}`)}
                  </p>
                ) : null}
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
                {SPAWN_CAPABILITIES.has(capability) ? (
                  <div className="mt-2 grid grid-cols-2 gap-2">
                    {(["max_spawns_per_run", "max_spawns_per_day"] as const).map((key) => (
                      <label className="block text-xs text-text-secondary" key={key}>
                        {t(`capabilities.${key}`)}
                        <Input
                          className="mt-1"
                          min={1}
                          onChange={(event) =>
                            setSpawnCaps((current) => ({
                              ...current,
                              [capability]: {
                                ...(current[capability] || DEFAULT_SPAWN_CAPS),
                                [key]: Math.max(1, Number.parseInt(event.target.value, 10) || 1)
                              }
                            }))
                          }
                          type="number"
                          value={(spawnCaps[capability] || DEFAULT_SPAWN_CAPS)[key]}
                        />
                      </label>
                    ))}
                    <button
                      className="col-span-2 rounded border border-border px-2 py-1 text-xs disabled:opacity-50"
                      disabled={!grant || mutation.isPending}
                      onClick={() => grant && saveSpawnCaps(grant)}
                      type="button"
                    >
                      {t("capabilities.save_spawn_caps")}
                    </button>
                  </div>
                ) : null}
                {descriptor.scopeable && descriptor.scope_options?.length ? (
                  <label className="mt-2 block text-xs text-text-secondary">
                    {t("capabilities.scope_for", { capability: descriptor.label })}
                    <Select
                      className="mt-1"
                      disabled={mutation.isPending}
                      onChange={(event) => changeScope(capability, event.target.value)}
                      value={JSON.stringify(scopes[capability] ?? descriptor.scope_options[0].value)}
                    >
                      {descriptor.scope_options.map((option) => (
                        <option key={JSON.stringify(option.value)} value={JSON.stringify(option.value)}>
                          {option.label}
                        </option>
                      ))}
                    </Select>
                  </label>
                ) : null}
              </div>
              <Select
                aria-label={t("capabilities.policy_for", { capability })}
                disabled={mutation.isPending}
                onChange={(event) => changePolicy(capability, event.target.value as keyof typeof POLICY_RANK)}
                value={grant?.approval_policy || "off"}
              >
                {(["auto", "confirm", "queue", "off"] as const)
                  .filter((policy) => POLICY_RANK[descriptor.maximum_policy] >= POLICY_RANK[policy])
                  .map((policy) => (
                    <option disabled={descriptor.available === false && policy !== "off"} key={policy} value={policy}>
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
    mutationFn: (schedule: { name: string; prompt: string; kind: string; schedule_input?: string; fire_at?: string; after_run: "wake" | "quiet" }) =>
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
      fire_at: kind === "one_shot" ? new Date(String(data.get("fire_at") || "")).toISOString() : undefined,
      after_run: data.get("after_run") === "quiet" ? "quiet" : "wake"
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
        <label className="block text-sm font-medium">
          {t("schedule.after_run")}
          <Select className="mt-1" defaultValue="wake" name="after_run">
            <option value="wake">{t("schedule.after_run_wake")}</option>
            <option value="quiet">{t("schedule.after_run_quiet")}</option>
          </Select>
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
                <div className="flex items-center gap-2 font-medium">
                  {schedule.name}
                  {schedule.system_key ? (
                    <span className="rounded bg-surface-muted px-2 py-0.5 text-xs text-text-secondary">{t("schedule.system")}</span>
                  ) : null}
                </div>
                <div className="text-sm text-text-secondary">
                  {schedule.schedule_explanation || schedule.fire_at} · {schedule.state} · {t(`schedule.after_run_${schedule.after_run}`)}
                </div>
                {schedule.system_key ? (
                  <>
                    {schedule.journaling_overdue ? (
                      <div className="text-sm font-medium text-danger-text" role="status">
                        {t("schedule.journaling_overdue", {
                          reason: schedule.last_system_result_reason || t("schedule.missed_fire")
                        })}
                      </div>
                    ) : null}
                    <SystemScheduleTime coworkerId={String(coworker.id)} onChanged={onChanged} schedule={schedule} />
                  </>
                ) : null}
                <LatestScheduleResult result={schedule.latest_result} />
                <Link className="text-sm text-brand hover:underline" to={`/dashboard/jobs?q=${scheduleFilter(schedule.id)}`}>
                  {t("schedule.view_all_runs")}
                </Link>
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

function scheduleFilter(id: number) {
  return encodeFilterTree({ and: [{ field: "scheduled_task_id", op: "is", value: String(id) }] })
}

function LatestScheduleResult({ result }: { result: CoworkerSchedule["latest_result"] }) {
  const { t } = useT("coworkers")
  const failure = ["failed", "blocked", "cancelled"].includes(result.outcome)
  return (
    <div className={`mt-2 text-sm ${failure ? "font-medium text-danger-text" : "text-text-secondary"}`} role={failure ? "alert" : undefined}>
      <span>
        {t("schedule.latest_result")}: {t(`schedule.outcomes.${result.outcome}`, { defaultValue: result.outcome })}
      </span>
      {result.target_date || result.occurred_at ? <span> · {result.target_date || new Date(result.occurred_at!).toLocaleString()}</span> : null}
      {result.job ? (
        <>
          {" · "}
          <Link className="underline" to={result.job.path}>
            {result.job.slug}
          </Link>
        </>
      ) : null}
      {result.job_needed === false ? <span> · {t("schedule.no_job_needed")}</span> : null}
      {result.reason ? <div>{result.reason}</div> : null}
    </div>
  )
}

function SystemScheduleTime({ coworkerId, schedule, onChanged }: { coworkerId: string; schedule: CoworkerSchedule; onChanged: () => void }) {
  const { t } = useT("coworkers")
  const [cadence, setCadence] = useState(schedule.schedule_input || "")
  const update = useMutation({
    mutationFn: () => updateCoworkerSchedule(coworkerId, schedule.id, { schedule_input: cadence }),
    onSuccess: onChanged
  })
  return (
    <div className="mt-2 flex items-center gap-2">
      <Input aria-label={t("schedule.system_run_time")} className="max-w-56" onChange={(event) => setCadence(event.target.value)} value={cadence} />
      <button
        className="rounded border border-border px-2 py-1 text-xs"
        disabled={update.isPending || cadence === schedule.schedule_input}
        onClick={() => update.mutate()}
      >
        {t("schedule.save_time")}
      </button>
    </div>
  )
}

function CoworkerActivity({ id }: { id: string }) {
  const { t } = useT("coworkers")
  const query = useQuery({ queryKey: ["coworkers", id, "activity"], queryFn: () => fetchCoworkerActivity(id) })
  const [olderRuns, setOlderRuns] = useState<Awaited<ReturnType<typeof fetchCoworkerActivity>>["runs"]>([])
  const [olderChats, setOlderChats] = useState<Awaited<ReturnType<typeof fetchCoworkerActivity>>["side_chats"]>([])
  const [nextCursors, setNextCursors] = useState<{ runs: string | null; side_chats: string | null }>({ runs: null, side_chats: null })
  useEffect(() => {
    if (query.data) setNextCursors(query.data.next_cursors)
  }, [query.data])
  const loadMore = useMutation({
    mutationFn: () => fetchCoworkerActivity(id, { runs: nextCursors.runs, sideChats: nextCursors.side_chats }),
    onSuccess: (page) => {
      setOlderRuns((current) => [...current, ...page.runs])
      setOlderChats((current) => [...current, ...page.side_chats])
      setNextCursors(page.next_cursors)
    }
  })
  if (query.isPending) return <PanelMessage>{t("activity.loading")}</PanelMessage>
  if (query.isError || !query.data) return <PanelMessage>{t("activity.unavailable")}</PanelMessage>
  const activity = query.data
  const runs = [...activity.runs, ...olderRuns]
  const sideChats = [...activity.side_chats, ...olderChats]
  const traffic = activity.message_traffic
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
        {runs.length ? (
          <ul className="mt-3 divide-y divide-border rounded border border-border">
            {runs.map((run) => (
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
        {sideChats.length ? (
          <ul className="mt-3 space-y-2">
            {sideChats.map((chat) => (
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
      {nextCursors.runs || nextCursors.side_chats ? (
        <button className="rounded border border-border px-3 py-2 text-sm" disabled={loadMore.isPending} onClick={() => loadMore.mutate()} type="button">
          {t("activity.load_more")}
        </button>
      ) : null}
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
  const location = useLocation()
  const navigate = useNavigate()
  const params = new URLSearchParams(location.search)
  const selectedPath = params.get("path") || undefined
  const workspaceSearch = useMemo(() => {
    const query = new URLSearchParams(location.search)
    query.delete("tab")
    query.delete("expanded")
    return query.size ? `?${query}` : ""
  }, [location.search])
  const selectPath = (path: string) => {
    const query = new URLSearchParams(location.search)
    query.set("tab", "workspace")
    query.set("path", path)
    navigate({ search: `?${query}` })
  }
  const setCursor = (cursor: string | null) => {
    const query = new URLSearchParams(location.search)
    cursor ? query.set("cursor", cursor) : query.delete("cursor")
    navigate({ search: `?${query}` })
  }
  const setExpandedPaths = (paths: Set<string>) => {
    const query = new URLSearchParams(location.search)
    paths.size ? query.set("expanded", [...paths].sort().join(",")) : query.delete("expanded")
    navigate({ search: `?${query}` }, { replace: true })
  }
  const query = useQuery({
    queryKey: ["coworkers", id, "workspace", workspaceSearch],
    queryFn: () => fetchCoworkerWorkspace(id, workspaceSearch)
  })
  const pushTest = useMutation({ mutationFn: () => testCoworkerRemote(remote) })
  const coworkerQuery = useQuery({ queryKey: ["coworkers", id, "chats"], queryFn: () => fetchCoworkerTab(id, "chats") })
  const unsavedChats = coworkerQuery.data?.chats?.filter((chat) => chat.unsaved_workspace) || []
  const retrySave = useMutation({
    mutationFn: (chatLinkId: number) => retryCoworkerWorkspaceSave(id, chatLinkId),
    onSuccess: () => void coworkerQuery.refetch()
  })
  const unsavedAlerts = unsavedChats.map((chat) => (
    <div className="rounded border border-warning bg-warning-subtle p-4 text-sm" key={chat.link_id} role="alert">
      <div className="font-semibold">{t("workspace.unsaved_title")}</div>
      <p className="mt-1">{t("workspace.unsaved_detail", { branch: chat.unsaved_workspace?.branch, attempts: chat.unsaved_workspace?.attempt_count })}</p>
      <p className="mt-1 break-words text-text-secondary">{chat.unsaved_workspace?.last_error}</p>
      <button
        className="mt-3 rounded border border-border bg-surface px-3 py-2 font-medium disabled:opacity-50"
        disabled={retrySave.isPending}
        onClick={() => retrySave.mutate(chat.link_id)}
        type="button"
      >
        {retrySave.isPending ? t("workspace.retrying_save") : t("workspace.retry_save")}
      </button>
    </div>
  ))

  if (query.isPending)
    return (
      <section className="space-y-4">
        {unsavedAlerts}
        <PanelMessage>{t("workspace.loading")}</PanelMessage>
      </section>
    )
  if (query.isError || !query.data)
    return (
      <section className="space-y-4">
        {unsavedAlerts}
        <PanelMessage>{t("workspace.unavailable")}</PanelMessage>
      </section>
    )
  const workspace = query.data
  const results = workspace.results || []
  const pathParts = selectedPath?.split("/") || []
  return (
    <section className="space-y-4">
      {unsavedAlerts}
      <div className="flex flex-wrap items-center justify-between gap-3 rounded border border-border bg-surface p-3 text-sm">
        <div>
          <div className="font-medium text-text-primary">{workspace.remote}</div>
          <div className="text-text-muted">{workspace.branch}</div>
          {Object.values(workspace.branch_counts).some((count) => count !== null) ? (
            <div className="mt-1 text-text-muted">{t("workspace.branch_counts", workspace.branch_counts)}</div>
          ) : null}
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
      {workspace.incomplete_reasons?.length ? <PanelMessage>{t("workspace.incomplete")}</PanelMessage> : null}
      {workspace.conflicts.map((conflict) => (
        <PanelMessage key={conflict.branch}>
          {t("workspace.conflict", { branch: conflict.branch })} {conflict.files.join(", ")}
        </PanelMessage>
      ))}
      <div className="grid min-h-96 overflow-hidden rounded border border-border bg-surface md:grid-cols-[18rem_minmax(0,1fr)]">
        <div className="border-b border-border p-3 md:border-b-0 md:border-r">
          <div className="mb-3 flex flex-wrap gap-2">
            <WorkspaceScope label={t("workspace.all")} location={location} navigate={navigate} />
            <WorkspaceScope label={t("workspace.memory")} location={location} navigate={navigate} prefix="memory" />
            <button className="rounded-full border border-border px-3 py-1 text-xs" onClick={() => selectPath("SOUL.md")} type="button">SOUL.md</button>
          </div>
          <FilterBar buildLink={workspaceFilterLink} filter={workspaceFilterTree(location.search)} filterSchema={workspaceFilterSchema(t)} legacyFilterKeys={["search", "extension", "path_prefix", "filename", "area"]} pathname={location.pathname} search={location.search} />
          <WorkspaceTree
            expandedPaths={new Set(params.get("expanded")?.split(",").filter(Boolean) || ["memory"])}
            files={workspace.files}
            label={t("workspace.files")}
            onExpandedChange={setExpandedPaths}
            onSelect={selectPath}
            selectedPath={selectedPath}
          />
        </div>
        <article className="min-w-0 p-5">
          {workspace.selected_file ? (
            <>
              <nav aria-label={t("workspace.breadcrumbs")} className="mb-3 flex flex-wrap gap-1 text-sm text-text-muted">
                {pathParts.map((part, index) => <span key={`${part}-${index}`}>{index ? " / " : ""}{part}</span>)}
              </nav>
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
            <div>
              <PanelMessage>{results.length ? t("workspace.choose_file") : t("workspace.no_results")}</PanelMessage>
              {results.map((result) => (
                <button className="mt-2 block w-full rounded border border-border p-3 text-left text-sm" key={result.path} onClick={() => selectPath(result.path)} type="button">
                  <span className="font-medium">{result.path}</span>
                  {result.snippet ? <HighlightedSnippet highlights={result.highlights} snippet={result.snippet} /> : null}
                </button>
              ))}
              {workspace.total > 0 ? (
                <div className="mt-4 flex items-center justify-between text-sm text-text-muted">
                  <span>{t("workspace.showing", { first: workspace.page_start, last: workspace.page_end, total: workspace.total })}</span>
                  <div className="flex gap-2">
                    <button className="rounded border border-border px-3 py-1 disabled:opacity-40" disabled={!workspace.previous_cursor} onClick={() => setCursor(workspace.previous_cursor)} type="button">{t("workspace.previous")}</button>
                    <button className="rounded border border-border px-3 py-1 disabled:opacity-40" disabled={!workspace.next_cursor} onClick={() => setCursor(workspace.next_cursor)} type="button">{t("workspace.next")}</button>
                  </div>
                </div>
              ) : null}
            </div>
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

function WorkspaceScope({ label, prefix, location, navigate }: { label: string; prefix?: string; location: ReturnType<typeof useLocation>; navigate: ReturnType<typeof useNavigate> }) {
  return <button className="rounded-full border border-border px-3 py-1 text-xs" onClick={() => { const query = new URLSearchParams(location.search); prefix ? query.set("path_prefix", prefix) : query.delete("path_prefix"); query.delete("path"); query.delete("cursor"); navigate({ search: `?${query}` }) }} type="button">{label}</button>
}

type WorkspaceTreeNode = { name: string; path: string; file: boolean; children: WorkspaceTreeNode[] }

function workspaceTreeNodes(files: CoworkerWorkspacePayload["files"]): WorkspaceTreeNode[] {
  const root: WorkspaceTreeNode = { name: "", path: "", file: false, children: [] }
  files.filter((file) => file.type === "file").forEach((file) => {
    let parent = root
    file.path.split("/").forEach((name, index, parts) => {
      const path = parts.slice(0, index + 1).join("/")
      let node = parent.children.find((child) => child.name === name)
      if (!node) {
        node = { name, path, file: index === parts.length - 1, children: [] }
        parent.children.push(node)
      }
      parent = node
    })
  })
  const sort = (nodes: WorkspaceTreeNode[]) => nodes.sort((a, b) => Number(a.file) - Number(b.file) || a.name.localeCompare(b.name)).forEach((node) => sort(node.children))
  sort(root.children)
  return root.children
}

function WorkspaceTree({ files, selectedPath, onSelect, label, expandedPaths, onExpandedChange }: { files: CoworkerWorkspacePayload["files"]; selectedPath?: string; onSelect: (path: string) => void; label: string; expandedPaths: Set<string>; onExpandedChange: (paths: Set<string>) => void }) {
  const treeRef = useRef<HTMLElement>(null)
  const nodes = workspaceTreeNodes(files)
  const [activePath, setActivePath] = useState(selectedPath)
  const visiblePaths = (treeNodes: WorkspaceTreeNode[]): string[] => treeNodes.flatMap((node) => [node.path, ...(!node.file && expandedPaths.has(node.path) ? visiblePaths(node.children) : [])])
  const tabStopPath = activePath && visiblePaths(nodes).includes(activePath) ? activePath : visiblePaths(nodes)[0]
  const toggle = (path: string, expand?: boolean) => {
    const next = new Set(expandedPaths)
    const shouldExpand = expand ?? !next.has(path)
    shouldExpand ? next.add(path) : next.delete(path)
    onExpandedChange(next)
  }
  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>, node: WorkspaceTreeNode) => {
    const items = [...(treeRef.current?.querySelectorAll<HTMLButtonElement>("[role=treeitem]") || [])]
    const index = items.indexOf(event.currentTarget)
    if (event.key === "ArrowDown" || event.key === "ArrowUp") items[index + (event.key === "ArrowDown" ? 1 : -1)]?.focus()
    else if (event.key === "Home") items[0]?.focus()
    else if (event.key === "End") items.at(-1)?.focus()
    else if (event.key === "ArrowRight" && !node.file) expandedPaths.has(node.path) ? items[index + 1]?.focus() : toggle(node.path, true)
    else if (event.key === "ArrowLeft") {
      if (!node.file && expandedPaths.has(node.path)) toggle(node.path, false)
      else event.currentTarget.closest("[role=group]")?.parentElement?.querySelector<HTMLButtonElement>(":scope > [role=treeitem]")?.focus()
    } else return
    event.preventDefault()
  }
  const renderNodes = (nodes: WorkspaceTreeNode[]): ReactNode => nodes.map((node) => (
    <li key={node.path} role="none">
      <button
        aria-current={node.file && selectedPath === node.path ? "page" : undefined}
        aria-expanded={node.file ? undefined : expandedPaths.has(node.path)}
        className={`block w-full rounded px-2 py-1 text-left text-sm ${node.file ? "hover:bg-surface-subtle" : "font-medium"}`}
        onClick={() => node.file ? onSelect(node.path) : toggle(node.path)}
        onFocus={() => setActivePath(node.path)}
        onKeyDown={(event) => onKeyDown(event, node)}
        role="treeitem"
        tabIndex={node.path === tabStopPath ? 0 : -1}
        type="button"
      >{node.file ? null : expandedPaths.has(node.path) ? "▾ " : "▸ "}{node.name}</button>
      {!node.file && expandedPaths.has(node.path) ? <ul className="pl-3" role="group">{renderNodes(node.children)}</ul> : null}
    </li>
  ))
  return <nav aria-label={label} className="mt-3 max-h-96 overflow-auto" ref={treeRef} role="tree"><ul role="none">{renderNodes(nodes)}</ul></nav>
}

function HighlightedSnippet({ snippet, highlights }: { snippet: string; highlights: { start: number; length: number }[] }) {
  const highlight = highlights[0]
  if (!highlight) return <span className="mt-1 block text-text-muted">{snippet}</span>
  return <span className="mt-1 block text-text-muted">{snippet.slice(0, highlight.start)}<mark>{snippet.slice(highlight.start, highlight.start + highlight.length)}</mark>{snippet.slice(highlight.start + highlight.length)}</span>
}

const workspaceFilterSchema = (t: (key: string) => string) => [
  { field: "search", label: t("workspace.search"), bucket: "text", operators: ["contains"], values: [], free_text_search: true },
  { field: "extension", label: t("workspace.extension"), bucket: "text", operators: ["is"], values: [] },
  { field: "path_prefix", label: t("workspace.folder"), bucket: "text", operators: ["is"], values: [] },
  { field: "folder", label: t("workspace.exact_folder"), bucket: "text", operators: ["is"], values: [] },
  { field: "filename", label: t("workspace.filename"), bucket: "text", operators: ["contains"], values: [] },
  { field: "filename_exact", label: t("workspace.filename_exact"), bucket: "text", operators: ["is"], values: [] },
  { field: "area", label: t("workspace.area"), bucket: "text", operators: ["is"], values: [] },
  { field: "min_size", label: t("workspace.min_size"), bucket: "number", operators: ["is"], values: [] },
  { field: "max_size", label: t("workspace.max_size"), bucket: "number", operators: ["is"], values: [] },
  { field: "modified_after", label: t("workspace.modified_after"), bucket: "date", operators: ["after"], values: [] },
  { field: "modified_before", label: t("workspace.modified_before"), bucket: "date", operators: ["before"], values: [] },
  {
    field: "content_kind",
    label: t("workspace.content_kind"),
    bucket: "select",
    operators: ["is"],
    values: [
      { value: "text", label: t("workspace.text") },
      { value: "binary", label: t("workspace.binary_kind") }
    ]
  },
  {
    field: "sort",
    label: t("workspace.sort"),
    bucket: "select",
    operators: ["is"],
    values: [
      { value: "path", label: t("workspace.sort_path") },
      { value: "size", label: t("workspace.sort_size") },
      { value: "modified", label: t("workspace.sort_modified") }
    ]
  }
]

function workspaceFilterTree(search: string): FilterTree {
  const params = new URLSearchParams(search)
  return { and: ["search", "extension", "folder", "path_prefix", "filename", "filename_exact", "area", "content_kind", "min_size", "max_size", "modified_after", "modified_before", "sort"].flatMap((field) => {
    const value = params.get(field)?.trim()
    const op = field === "search" || field === "filename" ? "contains" : field === "modified_after" ? "after" : field === "modified_before" ? "before" : "is"
    return value ? [{ field, op, value }] : []
  }) }
}

const workspaceFilterLink: FilterLinkBuilder = (path, search, updates) => {
  const params = new URLSearchParams(search)
  if (typeof updates.q === "string" && updates.q) {
    try {
      const encoded = updates.q.replace(/-/g, "+").replace(/_/g, "/")
      const tree = JSON.parse(atob(encoded)) as { and?: Array<{ field?: string; value?: unknown }> }
      const fields = ["search", "extension", "folder", "path_prefix", "filename", "filename_exact", "area", "content_kind", "min_size", "max_size", "modified_after", "modified_before", "sort"]
      fields.forEach((field) => {
        const value = tree.and?.find((chip) => chip.field === field)?.value
        if (typeof value === "string" && value.trim()) params.set(field, value.trim())
        else params.delete(field)
      })
    } catch {
      params.delete("search")
    }
  } else if (updates.q == null) ["search", "extension", "folder", "path_prefix", "filename", "filename_exact", "area", "content_kind", "min_size", "max_size", "modified_after", "modified_before", "sort"].forEach((field) => params.delete(field))
  params.delete("path")
  params.delete("cursor")
  const query = params.toString()
  return query ? `${path}?${query}` : path
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
