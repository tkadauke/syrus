import { useQuery } from "@tanstack/react-query"
import { useEffect, useState } from "react"

import { chatPreviewPanelFileUrl, fetchChatPreviewPanelFile } from "@app/api/chats"
import { Select } from "@app/components/Select"
import { Notice, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import type { MockupPanel } from "../api/mockups"

export function MockupPreviewPanel({ panel }: { panel: MockupPanel }) {
  const { t } = useT("mockups")
  const [versionId, setVersionId] = useState<number | null>(panel.current_version_id)

  useEffect(() => setVersionId(panel.current_version_id), [panel.id, panel.current_version_id])

  const version = panel.versions.find((entry) => entry.id === versionId) ?? null
  const entryPath = version?.entry_path ?? panel.entry_path
  const viewerKind = version?.entry_viewer_kind ?? panel.entry_viewer_kind
  const isHtml = viewerKind === "html"
  const rawUrl = chatPreviewPanelFileUrl(panel.app_file_base_path, entryPath, versionId, true)

  // The mockups gallery runs inside the main app shell, so render HTML through
  // the authenticated file endpoint instead of depending on the isolated
  // preview-panel origin being reachable from this viewport.
  const textQuery = useQuery({
    queryKey: ["mockup_panel_file", panel.id, versionId, entryPath],
    queryFn: () => fetchChatPreviewPanelFile(panel.app_file_base_path, entryPath, versionId),
    enabled: viewerKind === "html" || viewerKind === "markdown" || viewerKind === "unsupported",
    staleTime: Infinity,
    retry: false
  })

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex items-center gap-2 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
        {panel.versions.length > 1 ? (
          <Select
            aria-label={t("version")}
            className="text-xs"
            fullWidth={false}
            onChange={(event) => setVersionId(Number(event.target.value))}
            value={versionId ?? ""}
          >
            {panel.versions.map((entry) => (
              <option key={entry.id} value={entry.id}>
                {new Date(entry.created_at).toLocaleString()}
              </option>
            ))}
          </Select>
        ) : null}
        <Text as="span" className="truncate font-mono" size="xs" tone="muted">{entryPath}</Text>
        <a
          className="ml-auto text-xs text-brand underline hover:no-underline"
          href={panel.app_export_path}
        >
          {t("download")}
        </a>
      </div>

      {isHtml ? (
        textQuery.isPending ? (
          <Notice className="m-3">{t("loading")}</Notice>
        ) : textQuery.isError ? (
          <Notice className="m-3" tone="error">{t("preview_unavailable")}</Notice>
        ) : (
          <iframe
            className="h-full w-full min-h-0 flex-1 border-0 bg-white"
            referrerPolicy="no-referrer"
            sandbox="allow-scripts"
            srcDoc={textQuery.data?.content ?? ""}
            title={panel.title}
          />
        )
      ) : viewerKind === "pdf" ? (
        <iframe className="h-full w-full min-h-0 flex-1 border-0 bg-white" src={rawUrl} title={entryPath} />
      ) : viewerKind === "image" ? (
        <div className="min-h-0 flex-1 overflow-auto bg-gray-50 p-3 dark:bg-gray-900">
          <img alt={entryPath} className="mx-auto max-w-full" src={rawUrl} />
        </div>
      ) : (
        <div className="min-h-0 flex-1 overflow-auto">
          {textQuery.isPending ? (
            <Notice className="m-3">{t("loading")}</Notice>
          ) : textQuery.isError ? (
            <Notice className="m-3" tone="error">{t("preview_unavailable")}</Notice>
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
