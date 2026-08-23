module SyrusDev
  # Trivial proof-of-concept :workspace_tab provider (see
  # Syrus::Plugin::WorkspaceTab / config/syrus_docs/plugins.md). Exists to
  # verify the extension point end-to-end — registration, chat payload
  # serialization, tab bar rendering, lazy frontend component discovery —
  # without moving any real feature (like the whiteboard) into a plugin yet.
  class WorkspaceTabs
    include Syrus::Plugin::WorkspaceTab

    def self.workspace_tabs
      [
        {
          id: "syrus_dev.workspace_tab_demo",
          label: "Workspace Tab Demo",
          label_key: "syrus_dev:workspace_tab_demo_label",
          component: "syrus_dev/WorkspaceTabDemo",
          order: 100
        }
      ]
    end

    # Only meaningful in chats attached to a repository, to exercise the
    # optional per-chat visibility gate rather than always returning true.
    def self.available_for?(chat_session)
      chat_session.repository.present?
    end
  end
end
