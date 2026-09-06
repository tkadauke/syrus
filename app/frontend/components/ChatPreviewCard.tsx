import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { fetchChatPreview } from "../api/chats"
import { useT } from "../hooks/useT"
import { Avatar } from "./Avatar"
import { Card, Skeleton } from "./Card"
import { CopyableSlug } from "./CopyableSlug"
import { TonePill } from "./StatusPill"

export function ChatPreviewCard({ id, compact = false }: { id: number; compact?: boolean }) {
  const { t } = useT("chat")
  const { data, isPending } = useQuery({
    queryKey: ["chats", "preview", String(id)],
    queryFn: () => fetchChatPreview(String(id)),
    staleTime: 30_000,
  })

  if (isPending) return <ChatPreviewSkeleton compact={compact} />
  if (!data) return null

  const title = data.title_pending ? t("card_preview_generating_title") : data.title
  const pendingCount = data.pending_proposal_count + data.pending_actions_count

  return (
    <Card compact={compact} variant="preview">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <CopyableSlug className="text-xs" slug={data.chat_slug} />
        {pendingCount > 0 && (
          <TonePill tone="amber">{t("card_preview_pending", { count: pendingCount })}</TonePill>
        )}
      </div>
      {title && (
        <Link
          className={`mb-2 block text-sm font-medium text-gray-900 hover:underline dark:text-gray-100 ${compact ? "line-clamp-1" : "line-clamp-2"}`}
          to={`/chats/${id}`}
        >
          {title}
        </Link>
      )}
      {!compact && data.participants.length > 1 && (
        <div className="mb-3 flex -space-x-2">
          {data.participants.map((participant) => (
            <Avatar avatarUrl={participant.avatar_url} key={participant.id} name={participant.name} size="xs" />
          ))}
        </div>
      )}
      {!compact && (
        <Link className="text-xs text-brand hover:underline dark:text-brand-emphasis" to={`/chats/${id}`}>
          {t("card_preview_see_more")}
        </Link>
      )}
    </Card>
  )
}

export function ChatPreviewSkeleton({ compact = false }: { compact?: boolean }) {
  return (
    <Card compact={compact} variant="preview">
      <div className="mb-2 flex items-center gap-2">
        <Skeleton className="h-3 w-16" />
      </div>
      <div className="mb-3 space-y-1.5">
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-4 w-3/4" />
      </div>
    </Card>
  )
}
