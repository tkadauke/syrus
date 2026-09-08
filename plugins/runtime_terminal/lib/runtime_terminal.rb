require "runtime_terminal/data_cleanup"

module RuntimeTerminal
  extend Syrus::PluginApi

  syrus_plugin "runtime_terminal" do
    display_name "Runtime Terminal"
    description "Runtime Session adapter for Coding Mode CLI/TUI terminal sessions."
    long_description "Runtime Terminal adapts Syrus's existing Terminal plugin into DOC-17 Runtime Sessions " \
                     "for Coding Mode. It starts a real worker-side terminal in the chat workspace, records " \
                     "the RuntimeSession-to-Terminal::Session mapping in plugin-owned tables, and speaks " \
                     "Terminal::Relay's existing authenticated socket protocol for scrollback inspection and " \
                     "control-lease-gated input. The underlying Terminal plugin remains off by default and " \
                     "controls the shell relay."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/terminal.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled false
    disableable true
    depends_on [ "terminal" ]

    provides runtime_session_provider: "RuntimeTerminal::Provider"

    always do |scope|
      RuntimeTerminal::DataCleanup.install_into(scope)
    end
  end
end
