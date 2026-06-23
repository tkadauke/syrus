import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { ApiError } from "../api/client"
import { createChat, fetchNewChat, type NewChatPayload } from "../api/chats"
import { upsertRecentChatCache } from "../lib/chatRecentCache"

export function ChatNewRoute() {
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const form = useQuery({
    queryKey: ["chats", "new"],
    queryFn: fetchNewChat
  })

  return (
    <main aria-label="New chat" className="mx-auto max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-3xl font-semibold text-gray-900">New chat</h1>
      </header>

      {form.isPending ? <PanelMessage>Loading chat form...</PanelMessage> : null}
      {form.isError ? <PanelMessage tone="error">{errorMessage(form.error, "Unable to load the chat form.")}</PanelMessage> : null}
      {form.isSuccess ? <ChatForm payload={form.data} prefix={prefix} /> : null}
    </main>
  )
}

function ChatForm({ payload, prefix }: { payload: NewChatPayload; prefix: string }) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [repositoryId, setRepositoryId] = useState("")
  const [text, setText] = useState("")
  const save = useMutation({
    mutationFn: () => createChat({ repositoryId, text }),
    onSuccess: (created) => {
      upsertRecentChatCache(queryClient, created.chat)
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
      navigate(withRoutePrefix(created.redirect_to, prefix))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    save.mutate()
  }

  return (
    <form className="space-y-4 rounded border border-gray-200 bg-white p-4" onSubmit={submit}>
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to create chat.")}</PanelMessage> : null}

      <label className="block text-sm font-medium text-gray-700">
        Repository
        <select
          className={inputClass()}
          name="repository_id"
          onChange={(event) => setRepositoryId(event.target.value)}
          value={repositoryId}
        >
          <option value="">Attach later</option>
          {payload.repositories.map((repository) => (
            <option key={repository.id} value={repository.id}>{repository.slug}</option>
          ))}
        </select>
      </label>

      <label className="block text-sm font-medium text-gray-700">
        First message
        <textarea
          className={inputClass()}
          name="chat_message[text]"
          onChange={(event) => setText(event.target.value)}
          placeholder="Optional"
          rows={4}
          value={text}
        />
      </label>

      <button className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-gray-300" disabled={save.isPending} type="submit">
        {save.isPending ? "Creating..." : "Create chat"}
      </button>
    </form>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "mt-1 w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-blue-500"
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
