module App
  class SidebarPagesPayload
    def as_json(*)
      {
        pages: Syrus::PluginRegistry.providers_for(:sidebar_page)
          .flat_map { |provider| pages_for(provider) }
          .each_with_index.sort_by { |page, index| [ page[:order].to_i, index ] }
          .map(&:first)
      }
    end

    private

    def pages_for(provider)
      PerformanceLogging.plugin_call(extension_point: :sidebar_page, provider: provider, operation: :sidebar_pages) do
        Array(provider.sidebar_pages).map { |page| page_payload(page) }
      end
    end

    def page_payload(page)
      page = page.to_h.symbolize_keys
      {
        id: page.fetch(:id).to_s,
        label: page.fetch(:label).to_s,
        label_key: page[:label_key].presence&.to_s,
        path: page.fetch(:path).to_s,
        paths: Array(page[:paths].presence || page[:path]).map(&:to_s),
        component: page[:component].presence&.to_s,
        icon: page[:icon].presence&.to_s,
        order: page[:order].to_i
      }
    end
  end
end
