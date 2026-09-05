import { useQuery } from "@tanstack/react-query"
import { useEffect, useState } from "react"

import { chatPreviewPanelFileUrl, fetchChatPreviewPanelFile } from "@app/api/chats"
import { postJson } from "@app/api/client"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import type { MockupPanel } from "../api/mockups"

// An html panel is served from its own preview-panel-<id> origin, and a
// private one needs a short-lived token before that origin will answer. Same
// contract the chat sidebar uses; the panel routes are just not chat-scoped.
function usePanelAccessToken(panel: MockupPanel | null, enabled: boolean) {
  return useQuery({
    queryKey: ["mockup_panel_token", panel?.id],
    queryFn: () => postJson<{ token: string }>(panel!.app_token_path),
    enabled: enabled && !!panel && panel.visibility !== "public",
    staleTime: 60_000,
    retry: false
  })
}

function versionedUrl(panel: MockupPanel, versionId: number | null, token: string | null) {
  const params = new URLSearchParams()
  if (versionId) params.set("v", String(versionId))
  if (token) params.set("t", token)
  const query = params.toString()
  return `${panel.url}${query ? `?${query}` : ""}`
}

export function MockupPreviewPanel({ panel }: { panel: MockupPanel }) {
  const { t } = useT("mockups")
  const [versionId, setVersionId] = useState<number | null>(panel.current_version_id)

  useEffect(() => setVersionId(panel.current_version_id), [panel.id, panel.current_version_id])

  const version = panel.versions.find((entry) => entry.id === versionId) ?? null
  const entryPath = version?.entry_path ?? panel.entry_path
  const viewerKind = version?.entry_viewer_kind ?? panel.entry_viewer_kind
  const isHtml = viewerKind === "html"
  const rawUrl = chatPreviewPanelFileUrl(panel.app_file_base_path, entryPath, versionId, true)

  const accessToken = usePanelAccessToken(panel, isHtml)
  const token = panel.visibility === "public" ? null : accessToken.data?.token ?? null
  const canRender = !isHtml || panel.visibility === "public" || !!token

  // Markdown and anything unrecognised render as text, which is also how an
  // unknown plugin-registered viewer kind degrades.
  const textQuery = useQuery({
    queryKey: ["mockup_panel_file", panel.id, versionId, entryPath],
    queryFn: () => fetchChatPreviewPanelFile(panel.app_file_base_path, entryPath, versionId),
    enabled: viewerKind === "markdown" || viewerKind === "unsupported",
    staleTime: Infinity,
    retry: false
  })

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex items-center gap-2 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
        {panel.versions.length > 1 ? (
          <select
            aria-label={t("version")}
            className="rounded border border-gray-300 bg-white px-1.5 py-1 text-xs dark:border-gray-600 dark:bg-gray-900"
            onChange={(event) => setVersionId(Number(event.target.value))}
            value={versionId ?? ""}
          >
            {panel.versions.map((entry) => (
              <option key={entry.id} value={entry.id}>
                {new Date(entry.created_at).toLocaleString()}
              </option>
            ))}
          </select>
        ) : null}
        <span className="truncate font-mono text-xs text-gray-500 dark:text-gray-400">{entryPath}</span>
        <a
          className="ml-auto text-xs text-brand underline hover:no-underline"
          href={panel.app_export_path}
        >
          {t("download")}
        </a>
      </div>

      {!canRender ? (
        <PanelMessage>{t("preview_access_pending")}</PanelMessage>
      ) : isHtml ? (
        <iframe
          className="h-full w-full min-h-0 flex-1 border-0"
          referrerPolicy="no-referrer"
          sandbox="allow-scripts"
          src={versionedUrl(panel, versionId, token)}
          title={panel.title}
        />
      ) : viewerKind === "pdf" ? (
        <iframe className="h-full w-full min-h-0 flex-1 border-0 bg-white" src={rawUrl} title={entryPath} />
      ) : viewerKind === "image" ? (
        <div className="min-h-0 flex-1 overflow-auto bg-gray-50 p-3 dark:bg-gray-900">
          <img alt={entryPath} className="mx-auto max-w-full" src={rawUrl} />
        </div>
      ) : (
        <div className="min-h-0 flex-1 overflow-auto">
          {textQuery.isPending ? (
            <PanelMessage>{t("loading")}</PanelMessage>
          ) : textQuery.isError ? (
            <PanelMessage>{t("preview_unavailable")}</PanelMessage>
          ) : (
            <pre className="whitespace-pre-wrap break-words p-3 font-mono text-xs text-gray-700 dark:text-gray-300">
              {textQuery.data?.content ?? ""}
            </pre>
          )}
        </div>
      )}
    </div>
  )
}
