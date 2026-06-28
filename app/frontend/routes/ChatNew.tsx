import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useEffect } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { ApiError } from "../api/client"
import { createChat, fetchChats } from "../api/chats"
import { updateRecentChatCache } from "../lib/chatCache"
import { firstUnstartedChat } from "../lib/unstartedChat"

export function ChatNewRoute() {
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const prefix = routePrefix(location.pathname)
  const chats = useQuery({
    queryKey: ["chats", "recent"],
    queryFn: fetchChats
  })
  const save = useMutation({
    mutationFn: () => createChat({ repositoryId: "", text: "" }),
    onSuccess: (created) => {
      updateRecentChatCache(queryClient, created.chat, { prepend: true })
      navigate(withRoutePrefix(created.redirect_to, prefix))
    }
  })
  const { error: saveError, isError: saveIsError, isIdle: saveIsIdle, isPending: saveIsPending, mutate: createUnstartedChat } = save

  useEffect(() => {
    if (!chats.isSuccess || !saveIsIdle) return

    const unstartedChat = firstUnstartedChat(chats.data)
    if (unstartedChat) {
      navigate(withRoutePrefix(unstartedChat.chat_path, prefix), { replace: true })
      return
    }

    createUnstartedChat()
  }, [chats.isSuccess, chats.data, createUnstartedChat, navigate, prefix, saveIsIdle])

  return (
    <main aria-label="New chat" className="mx-auto max-w-3xl p-6">
      {chats.isPending || saveIsPending ? <PanelMessage>Opening chat...</PanelMessage> : null}
      {chats.isError ? <PanelMessage tone="error">{errorMessage(chats.error, "Unable to load recent chats.")}</PanelMessage> : null}
      {saveIsError ? <PanelMessage tone="error">{errorMessage(saveError, "Unable to open chat.")}</PanelMessage> : null}
    </main>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
