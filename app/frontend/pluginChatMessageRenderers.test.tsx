import { act, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { usePluginContributions } from "./hooks/usePluginContributions"
import { pluginChatMessageComponentFor, type PluginChatMessageProps } from "./pluginChatMessageRenderers"
import { preloadPluginContributions, registerPluginContribution, registerPluginContributionPreloader } from "./pluginContributionRegistry"

function LateRendererConsumer() {
  usePluginContributions()
  const Component = pluginChatMessageComponentFor("late_renderer_test/Message")
  return Component ? <Component {...({} as PluginChatMessageProps)} /> : <span>Existing fallback</span>
}

describe("plugin chat message renderers", () => {
  it("shows the existing fallback before preload finishes and updates after registration", async () => {
    let release!: () => void
    const loading = new Promise<void>((resolve) => { release = resolve })
    registerPluginContributionPreloader("late_renderer_test", async () => {
      await loading
      registerPluginContribution("chat_message_renderer", "late_renderer_test", "Message", {
        default: () => <span>Late plugin message</span>
      })
    })

    const preload = preloadPluginContributions(["late_renderer_test"])
    render(<LateRendererConsumer />)
    expect(screen.getByText("Existing fallback")).toBeInTheDocument()

    await act(async () => {
      release()
      await preload
    })

    expect(screen.getByText("Late plugin message")).toBeInTheDocument()
    expect(screen.queryByText("Existing fallback")).not.toBeInTheDocument()
  })
})
