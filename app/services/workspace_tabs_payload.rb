# Resolves plugin-declared chat workspace sidebar tabs (see
# Syrus::Plugin::WorkspaceTab / config/syrus_docs/plugins.md) for a given
# chat, mirroring Admin::PluginPagesPayload's :admin_page resolution.
class WorkspaceTabsPayload
  def initialize(chat_session)
    @chat_session = chat_session
  end

  def as_json(*)
    Syrus::PluginRegistry.providers_for(:workspace_tab)
      .select { |provider| available?(provider) }
      .flat_map { |provider| tabs_for(provider) }
      .sort_by { |tab| [ tab[:order], tab[:label] ] }
  end

  private

  def available?(provider)
    return true unless provider.respond_to?(:available_for?)

    PerformanceLogging.plugin_call(extension_point: :workspace_tab, provider: provider, operation: :available_for?) do
      provider.available_for?(@chat_session)
    end
  end

  def tabs_for(provider)
    PerformanceLogging.plugin_call(extension_point: :workspace_tab, provider: provider, operation: :workspace_tabs) do
      Array(provider.workspace_tabs).map { |tab| tab_payload(tab) }
    end
  end

  def tab_payload(tab)
    tab = tab.to_h.symbolize_keys
    {
      id: tab.fetch(:id).to_s,
      label: tab.fetch(:label).to_s,
      label_key: tab[:label_key].presence&.to_s,
      component: tab.fetch(:component).to_s,
      order: tab[:order].to_i
    }
  end
end
