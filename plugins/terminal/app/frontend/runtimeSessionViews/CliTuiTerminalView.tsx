import { useState } from "react"
import { useT } from "@app/hooks/useT"
import { TerminalStream, type TerminalConnectionState } from "../components/TerminalStream"
import type { PluginRuntimeSessionView, PluginRuntimeSessionViewProps } from "@app/pluginRuntimeSessionViews"

function terminalSessionIdFor(metadata: Record<string, unknown> | null | undefined): number | null {
  const value = metadata?.terminal_session_id
  const id = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN
  return Number.isInteger(id) && id > 0 ? id : null
}

function CliTuiTerminalView({ session, inputEnabled, onConnectionChange }: PluginRuntimeSessionViewProps) {
  const { t } = useT("chat")
  const [connection, setConnection] = useState<TerminalConnectionState>({ connected: true, ended: false })
  const terminalSessionId = terminalSessionIdFor(session.metadata)

  if (terminalSessionId == null) return null

  return (
    <div>
      <TerminalStream
        className="relative h-72 min-h-0 overflow-hidden rounded border border-gray-200 dark:border-gray-700"
        containerClassName="h-full overflow-hidden bg-gray-900 p-2"
        inputEnabled={inputEnabled}
        onConnectionChange={(state) => {
          setConnection(state)
          onConnectionChange?.(state)
        }}
        terminalSessionId={terminalSessionId}
      />
      <p className={`mt-1 text-xs ${connection.connected ? "text-emerald-600 dark:text-emerald-400" : "text-gray-500 dark:text-gray-400"}`}>
        {connection.connected ? t("runtime_terminal_connected") : t("runtime_terminal_disconnected")}
      </p>
    </div>
  )
}

const view: PluginRuntimeSessionView = {
  providerKey: "cli_tui",
  component: CliTuiTerminalView
}

export default view
