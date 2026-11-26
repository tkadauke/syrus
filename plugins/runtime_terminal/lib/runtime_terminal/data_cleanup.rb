module RuntimeTerminal
  # Removes adapter-owned link rows when core RuntimeSession records go away.
  #
  # Installed with `always`: disabling the adapter stops new CLI/TUI runtime
  # sessions, but existing mapping rows still belong to the plugin and should
  # not outlive their parent RuntimeSession.
  module DataCleanup
    def self.install_into(scope)
      scope.effect("runtime session terminal links") do
        Syrus::DataCleanup.register("RuntimeSession", "runtime_terminal.session_links") do |runtime_session|
          RuntimeTerminal::SessionLink.where(runtime_session_id: runtime_session.id).find_each(&:destroy)
        end
      end
    end
  end
end
