import { act, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it } from "vitest"
import i18n, { pluginNamespacesFor } from "./i18n"
import { renderPluginChatMessage, type PluginChatMessageProps } from "./pluginChatMessageRenderers"

// Plugin message renderers are bundled eagerly, so nothing preloads their
// plugin's translations before they mount. The test setup preloads every
// plugin's locales, which hid the bug: drop them here so the namespace is
// genuinely missing, as it is on a fresh page load in production.
function dropPluginLocales(plugin: string) {
  const removed: Array<[string, string, unknown]> = []
  // i18next also remembers which language|namespace pairs its backend has
  // loaded; reset that too, or the namespace still counts as ready.
  const backendState = (i18n.services.backendConnector as unknown as { state: Record<string, number> }).state
  for (const namespace of pluginNamespacesFor(plugin)) {
    for (const language of Object.keys(i18n.store.data)) {
      const bundle = i18n.getResourceBundle(language, namespace)
      if (!bundle) continue
      removed.push([language, namespace, bundle])
      i18n.removeResourceBundle(language, namespace)
      delete backendState[`${language}|${namespace}`]
    }
  }
  return () => removed.forEach(([language, namespace, bundle]) => i18n.addResourceBundle(language, namespace, bundle, true, true))
}

const restorers: Array<() => void> = []
afterEach(() => restorers.splice(0).forEach((restore) => restore()))

function props(): PluginChatMessageProps {
  return {
    item: { id: 1, role: "assistant", text: "Hello from Maya", created_at: new Date().toISOString() } as PluginChatMessageProps["item"],
    payload: { messages: [], pending_actions: [], pending_action_groups: [] } as unknown as PluginChatMessageProps["payload"],
    presentation: { component: "coworkers/CoworkerMessage", data: { handle: "maya", direction: "incoming" } },
    prefix: "",
    queryKey: [ "chats", 1 ] as unknown as PluginChatMessageProps["queryKey"],
    readOnly: true,
    entranceClass: "",
    onNotice: () => {}
  }
}

describe("renderPluginChatMessage", () => {
  // Regression: a coworker message rendered before the coworkers namespace was
  // loaded suspended inside a synchronous update, and React threw #426
  // ("A component suspended while responding to synchronous input"), taking
  // the whole chat page down.
  it("renders a plugin message without suspending while its translations load", async () => {
    restorers.push(dropPluginLocales("coworkers"))
    const client = new QueryClient()

    // No Suspense boundary: a suspending renderer would leave nothing on screen.
    act(() => {
      render(
        <QueryClientProvider client={client}>
          <MemoryRouter>{renderPluginChatMessage(props())}</MemoryRouter>
        </QueryClientProvider>
      )
    })

    expect(screen.getByText("Hello from Maya")).toBeInTheDocument()
    await waitFor(() => expect(document.querySelector("[data-plugin-message-loading]")).toBeNull())
    expect(screen.getByText("Hello from Maya")).toBeInTheDocument()
  })
})
