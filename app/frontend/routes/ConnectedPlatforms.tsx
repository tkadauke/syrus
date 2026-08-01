import { createConsumer } from "@rails/actioncable"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useEffect, useRef, useState } from "react"
import { NoticeToast } from "../components/NoticeToast"
import {
  createLinkingToken,
  deletePlatformIdentity,
  fetchPlatformIdentities,
  type AvailablePlatform,
  type LinkingTokenPayload,
  type PlatformIdentitiesPayload,
  type PlatformIdentity
} from "../api/platformIdentities"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["platform_identities"] as const

export function ConnectedPlatformsRoute() {
  const { t } = useT("settings")
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label={t("connected_platforms.heading")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("connected_platforms.heading")}</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("connected_platforms.description")}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <ConnectedPlatformsPanel onNotice={setNotice} />
    </main>
  )
}

function ConnectedPlatformsPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const result = useQuery({
    queryKey,
    queryFn: fetchPlatformIdentities
  })

  if (result.isPending) return <PanelMessage>{t("connected_platforms.loading")}</PanelMessage>
  if (result.isError) return <PanelMessage tone="error">{errorMessage(result.error, t("connected_platforms.error_load"))}</PanelMessage>

  return <PlatformsView onNotice={onNotice} payload={result.data} />
}

function PlatformsView({ payload, onNotice }: { payload: PlatformIdentitiesPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()

  const disconnect = useMutation({
    mutationFn: (id: number) => deletePlatformIdentity(id),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("connected_platforms.disconnected_notice"))
    }
  })

  return (
    <section className="divide-y divide-gray-200 dark:divide-gray-700 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      {payload.available_platforms.map((ap) => {
        const linked = payload.platform_identities.find((pi) => pi.platform === ap.platform)
        return (
          <PlatformRow
            key={ap.platform}
            availablePlatform={ap}
            disconnectPending={disconnect.isPending && disconnect.variables === linked?.id}
            identity={linked}
            onConnect={(updated) => {
              queryClient.setQueryData(queryKey, updated)
            }}
            onDisconnect={() => linked && disconnect.mutate(linked.id)}
            onNotice={onNotice}
          />
        )
      })}
    </section>
  )
}

function PlatformRow({
  availablePlatform,
  identity,
  disconnectPending,
  onConnect,
  onDisconnect,
  onNotice
}: {
  availablePlatform: AvailablePlatform
  identity: PlatformIdentity | undefined
  disconnectPending: boolean
  onConnect: (payload: PlatformIdentitiesPayload) => void
  onDisconnect: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("settings")
  const label = availablePlatform.label || availablePlatform.platform
  const [linkingToken, setLinkingToken] = useState<LinkingTokenPayload | null>(null)
  const [linkError, setLinkError] = useState<string | null>(null)

  const connect = useMutation({
    mutationFn: () => createLinkingToken(availablePlatform.platform),
    onSuccess: (result) => {
      setLinkingToken(result)
      setLinkError(null)
      onNotice(null)
    },
    onError: (err) => {
      setLinkError(errorMessage(err, t("connected_platforms.error_start_linking", { platform: label })))
    }
  })

  function handleDisconnect() {
    if (window.confirm(t("connected_platforms.disconnect_confirm", { platform: label }))) {
      setLinkingToken(null)
      setLinkError(null)
      onDisconnect()
    }
  }

  return (
    <div className="p-5">
      <div className="flex items-center justify-between gap-4">
        <div>
          <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{label}</div>
          {identity ? (
            <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
              {identity.external_handle
                ? t("connected_platforms.connected_as_since", { handle: identity.external_handle, date: new Date(identity.linked_at).toLocaleDateString() })
                : t("connected_platforms.connected_since", { date: new Date(identity.linked_at).toLocaleDateString() })}
            </p>
          ) : (
            <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{t("connected_platforms.not_connected")}</p>
          )}
        </div>

        <div className="flex shrink-0 gap-2">
          {identity ? (
            <button
              className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:text-red-300 dark:disabled:text-red-500"
              disabled={disconnectPending}
              onClick={handleDisconnect}
              type="button"
            >
              {disconnectPending ? t("connected_platforms.disconnecting") : t("connected_platforms.disconnect")}
            </button>
          ) : availablePlatform.configured ? (
            <button
              className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:bg-blue-300 dark:disabled:bg-blue-900"
              disabled={connect.isPending}
              onClick={() => connect.mutate()}
              type="button"
            >
              {connect.isPending
                ? t("connected_platforms.generating_link")
                : linkingToken
                  ? t("connected_platforms.regenerate_link")
                  : t("connected_platforms.connect")}
            </button>
          ) : (
            <button
              className="rounded border border-gray-200 dark:border-gray-700 px-3 py-1.5 text-sm text-gray-400 dark:text-gray-500 cursor-not-allowed"
              disabled
              title={t("connected_platforms.not_available_title")}
              type="button"
            >
              {t("connected_platforms.not_available")}
            </button>
          )}
        </div>
      </div>

      {linkError ? (
        <p className="mt-3 text-xs text-red-700 dark:text-red-300">{linkError}</p>
      ) : null}

      {linkingToken && !identity ? (
        <LinkingInstructions
          onLinked={onConnect}
          onNotice={onNotice}
          platform={availablePlatform.platform}
          tokenPayload={linkingToken}
        />
      ) : null}
    </div>
  )
}

function LinkingInstructions({
  platform,
  tokenPayload,
  onLinked,
  onNotice
}: {
  platform: string
  tokenPayload: LinkingTokenPayload
  onLinked: (payload: PlatformIdentitiesPayload) => void
  onNotice: (message: string | null) => void
}) {
  const [copied, setCopied] = useState(false)
  const { t } = useT("settings")
  const onLinkedRef = useRef(onLinked)
  onLinkedRef.current = onLinked

  useEffect(() => {
    const consumer = createConsumer()
    const subscription = consumer.subscriptions.create(
      { channel: "AppUserChannel" },
      {
        received(data: unknown) {
          const event = data as { type?: string; payload?: PlatformIdentitiesPayload }
          if (event.type === "platform_identity_linked" && event.payload) {
            onLinkedRef.current(event.payload)
            const linkedPlatform = event.payload.available_platforms.find((ap) => ap.platform === platform)
            onNotice(t("connected_platforms.connected_notice", { platform: linkedPlatform?.label || platform }))
          }
        }
      }
    )

    return () => subscription.unsubscribe()
  }, [platform, onNotice, t])

  async function copyToken() {
    try {
      await navigator.clipboard.writeText(`/start ${tokenPayload.token}`)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      setCopied(false)
    }
  }

  return (
    <div className="mt-3 rounded border border-blue-100 dark:border-blue-900/60 bg-blue-50 dark:bg-blue-950/40 p-3 text-sm text-blue-950 dark:text-blue-100">
      <p className="font-medium">{t("connected_platforms.how_to_connect")}</p>
      <p className="mt-1 text-xs">{tokenPayload.instructions.text}</p>
      {tokenPayload.instructions.bot_handle ? (
        <div className="mt-2 flex items-center gap-2">
          <code className="flex-1 rounded bg-blue-100 dark:bg-blue-900/60 px-2 py-1 font-mono text-xs break-all">
            /start {tokenPayload.token}
          </code>
          <button
            className="shrink-0 rounded border border-blue-300 dark:border-blue-700 px-2 py-1 text-xs text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-900/60"
            onClick={copyToken}
            type="button"
          >
            {copied ? t("connected_platforms.copied") : t("connected_platforms.copy")}
          </button>
        </div>
      ) : null}
      <p className="mt-2 text-xs text-blue-700 dark:text-blue-300">{t("connected_platforms.expires_waiting")}</p>
    </div>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    muted: "border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}
