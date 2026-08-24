module Syrus
  module Plugin
    # Interface for `:workspace_tab` extension points. Plugin gems declare
    # additional tabs for the chat workspace sidebar, generalizing what used to
    # be a hardcoded closed union (see `WorkspaceTab` in
    # app/frontend/routes/chat/workspaceTabs.ts).
    #
    # Rendering follows the same declarative-metadata + core-glob-discovery
    # pattern as `:admin_page` (see Syrus::Plugin::AdminPage /
    # app/frontend/pluginAdminPages.tsx) rather than a fixed `renderer_type`
    # dispatch like `:artifact_renderer`: a plugin supplies a `component` key
    # naming a React component under its own `app/frontend/workspaceTabs/`,
    # discovered by app/frontend/pluginWorkspaceTabs.tsx via `import.meta.glob`.
    # See config/syrus_docs/plugins.md for why a fixed renderer-type dispatch
    # was rejected for this extension point.
    #
    #   class MyPlugin::WorkspaceTabs
    #     include Syrus::Plugin::WorkspaceTab
    #
    #     def self.workspace_tabs
    #       [ { id: "my_plugin.status", label: "Status", label_key: "my_plugin:tab_status",
    #           component: "my_plugin/StatusTab", order: 100 } ]
    #     end
    #
    #     def self.available_for?(chat_session) = true
    #   end
    #
    #   Syrus::PluginRegistry.register(
    #     name: "my_plugin", version: "1.0.0",
    #     provides: { workspace_tab: MyPlugin::WorkspaceTabs }
    #   )
    module WorkspaceTab
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # @return [Array<Hash>] tab metadata, each with :id, :label
        #   (or :label_key), :component, and optionally :order.
        def workspace_tabs
          raise NotImplementedError, "#{name} must implement .workspace_tabs"
        end

        # Optional per-chat visibility gate. Defaults to always available;
        # override to hide the tab unless the chat has whatever this
        # plugin's tab needs (a data source, a feature flag, ...).
        def available_for?(_chat_session)
          true
        end
      end
    end
  end
end
