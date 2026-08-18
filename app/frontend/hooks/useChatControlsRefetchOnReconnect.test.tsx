import { act, render } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { useState } from "react"
import { describe, expect, it, vi } from "vitest"
import { ConnectionContext } from "../lib/connectionContext"
import { useChatControlsRefetchOnReconnect } from "./useChatControlsRefetchOnReconnect"

function Probe({ chatId }: { chatId: string }) {
  useChatControlsRefetchOnReconnect(chatId)
  return null
}

function renderWithReconnectControl({
  queryClient,
  chatId,
  initialReconnectAt = null
}: {
  queryClient: QueryClient
  chatId: string
  initialReconnectAt?: number | null
}) {
  let setReconnectAt: (at: number | null) => void = () => {}

  function Wrapper() {
    const [reconnectAt, setAt] = useState<number | null>(initialReconnectAt)
    setReconnectAt = setAt
    return (
      <QueryClientProvider client={queryClient}>
        <ConnectionContext.Provider value={{ reconnectAt }}>
          <Probe chatId={chatId} />
        </ConnectionContext.Provider>
      </QueryClientProvider>
    )
  }

  render(<Wrapper />)

  return {
    simulateReconnect: (at = Date.now()) => act(() => setReconnectAt(at))
  }
}

describe("useChatControlsRefetchOnReconnect", () => {
  it("refetches the chat query on reconnect", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const refetch = vi.spyOn(queryClient, "refetchQueries").mockResolvedValue(undefined as never)

    const { simulateReconnect } = renderWithReconnectControl({ queryClient, chatId: "42" })

    await simulateReconnect(1000)

    expect(refetch).toHaveBeenCalledWith({ queryKey: ["chats", "42"] })
  })

  it("does not refetch on initial mount when reconnectAt is already set", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const refetch = vi.spyOn(queryClient, "refetchQueries").mockResolvedValue(undefined as never)

    // Simulate the chat mounting after a reconnect already happened (reconnectAt is pre-set).
    const { simulateReconnect } = renderWithReconnectControl({
      queryClient,
      chatId: "42",
      initialReconnectAt: 500
    })

    // No refetch fires on mount — lastSeenReconnectAtRef is initialized to the current value.
    expect(refetch).not.toHaveBeenCalled()

    // A new reconnect with a different timestamp does trigger the refetch.
    await simulateReconnect(1500)
    expect(refetch).toHaveBeenCalledWith({ queryKey: ["chats", "42"] })
  })

  it("refetches on each new reconnect", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const refetch = vi.spyOn(queryClient, "refetchQueries").mockResolvedValue(undefined as never)

    const { simulateReconnect } = renderWithReconnectControl({ queryClient, chatId: "42" })

    await simulateReconnect(1000)
    expect(refetch).toHaveBeenCalledTimes(1)

    await simulateReconnect(2000)
    expect(refetch).toHaveBeenCalledTimes(2)
  })
})
