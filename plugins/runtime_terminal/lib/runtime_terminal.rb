module RuntimeTerminal
  extend Syrus::PluginApi

  syrus_plugin "runtime_terminal" do
    display_name "Runtime Terminal"
    description "Runtime Session adapter for Coding Mode CLI/TUI terminal sessions."
    long_description "Runtime Terminal adapts Syrus's existing Terminal plugin into DOC-17 Runtime Sessions for Coding Mode. It starts a real worker-side terminal in the chat workspace and records the RuntimeSession-to-Terminal::Session mapping in plugin-owned tables. The underlying Terminal plugin remains off by default and controls the shell relay; this adapter only exposes lifecycle start/stop in the generic runtime session surface."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/terminal.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled false
    disableable true
    depends_on [ "terminal" ]

    provides runtime_session_provider: "RuntimeTerminal::Provider"
  end
end
