module GlobalSearch
  class SourceBackfill
    def self.run! = new.run!

    def run!
      providers.each do |provider|
        backfill_provider(provider)
      end
    end

    private

    def providers
      Syrus::PluginRegistry.providers_for("global_search:source")
    end

    def backfill_provider(provider)
      table_names(provider).each do |table_name|
        hook = backfill_hook(provider)
        next unless hook

        hook.call(table_name)
      rescue StandardError => e
        Rails.logger&.error(
          "[global_search] source backfill failed for #{provider} table #{table_name.inspect}: " \
          "#{e.class}: #{e.message}"
        )
      end
    rescue StandardError => e
      Rails.logger&.error("[global_search] source backfill failed for #{provider}: #{e.class}: #{e.message}")
    end

    def table_names(provider)
      return [] unless provider.respond_to?(:search_tables)

      Array(provider.search_tables).to_h.keys.map(&:to_s)
    end

    def backfill_hook(provider)
      if provider.respond_to?(:backfill_search_table)
        ->(table_name) { provider.backfill_search_table(table_name) }
      elsif provider.respond_to?(:rebuild_search_table)
        ->(table_name) { provider.rebuild_search_table(table_name) }
      end
    end
  end
end
