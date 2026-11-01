module MaintenanceTasks
  module Definitions
    class SearchDatabaseRebuild < Base
      PLAN_KEY = "rebuild_plan"

      key "search_database_rebuild"
      title "Rebuild search database"
      summary "Creates missing search tables and selectively rebuilds stale search entities."
      category "index"
      recurrence "repeatable"
      required_role "admin"
      concurrency_key "search_database_rebuild"
      batch_size 250
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/search_database_rebuild.md")

      step "schema", "Prepare search schema", "Creates or repairs the local SQLite FTS tables used by global search."
      step "chats", "Index chat messages", "Indexes searchable user and assistant chat messages."
      step "jobs", "Index jobs", "Indexes jobs when Global Search is installed."
      step "epics", "Index epics", "Indexes epics when Global Search is installed."
      step "logs", "Index operational logs", "Indexes operational logs when instance logging is configured."

      def estimate_total_units
        estimate_units(rebuild_plan)
      end

      def pending? = rebuild_plan.any?
      def pending_reason = pending_reason_for(rebuild_plan)

      def build_task_attributes(**arguments)
        plan = rebuild_plan
        super(**arguments).deep_merge(
          total_units: estimate_units(plan),
          checkpoint: { PLAN_KEY => plan },
          metadata: { PLAN_KEY => plan, "pending_reason" => pending_reason_for(plan) }
        )
      end

      def revival_checkpoint(task)
        { PLAN_KEY => rebuild_plan.presence || Array(task.metadata[PLAN_KEY]) }
      end

      def perform_batch(task)
        plan = task_plan(task)
        unless task.checkpoint["schema_prepared"]
          schema = plan.find { |entry| entry["entity"] == "schema" }
          return prepare_schema(task, plan, schema) if schema || selected_schema_missing?(plan)

          change_checkpoint(task) { task.checkpoint["schema_prepared"] = true }
        end

        plan.each do |entry|
          entity = entry.fetch("entity")
          next if entity == "schema" || task.checkpoint["#{entity}_done"]
          return mark_done(task, entity, "#{entity.humanize} index is already current.") unless selected_entry_pending?(entry)

          return process_entity(task, entry)
        end
        Result.new(done: true, processed: 0, failed: 0, message: "Selected search database rebuilds are complete.", level: "info", metadata: { PLAN_KEY => plan })
      end

      private

      def rebuild_plan
        missing = SyrusSearchDatabaseTasks.required_table_sql.keys.reject { |table| SyrusSearchDatabaseTasks.table_exists?(table) }
        plan = []
        plan << entry("schema", nil, nil, "missing_schema", "tables" => missing) if missing.any?
        versioned_sources.each do |source|
          source.search_database_initialize_content_version! if source.respond_to?(:search_database_initialize_content_version!) && source_tables(source).none? { |table| missing.include?(table) }
          key = source.search_database_rebuild_key.to_s
          current = source.current_content_version&.to_s
          target = source.search_database_content_version.to_s
          reason = if source_tables(source).intersect?(missing)
            "missing_schema"
          elsif current != target
            "version_mismatch"
          elsif source.search_database_integrity_repair_needed?
            "integrity_repair"
          end
          plan << entry(key, current, target, reason) if reason
        end
        plan
      end

      def entry(entity, current, target, reason, extra = {})
        { "entity" => entity, "current_version" => current, "target_version" => target, "reason" => reason }.merge(extra)
      end

      def pending_reason_for(plan)
        deltas = plan.map do |item|
          item["reason"] == "version_mismatch" ? "#{item['entity']} #{item['current_version'] || 'unversioned'} → #{item['target_version']}" : "#{item['entity']} (#{item['reason'].tr('_', ' ')})"
        end
        "Search rebuild required: #{deltas.join(', ')}."
      end

      def task_plan(task) = Array(task.checkpoint[PLAN_KEY]).presence || Array(task.metadata[PLAN_KEY]).presence || rebuild_plan

      def prepare_schema(task, plan, schema)
        task.current_step_key = "schema"
        task.current_step_title = "Prepare search schema"
        SyrusSearchDatabaseTasks.prepare!
        change_checkpoint(task) do
          task.checkpoint["schema_prepared"] = true
          task.checkpoint["schema_done"] = true if schema
        end
        Result.new(done: false, processed: 1, failed: 0, message: "Prepared search database schema.", level: "progress", metadata: { PLAN_KEY => plan })
      end

      def process_entity(task, item)
        source = source_for(item.fetch("entity"))
        return mark_done(task, item.fetch("entity"), "#{item.fetch('entity').humanize} index is unavailable.") unless source

        PerformanceLogging.plugin_call(extension_point: "global_search:source", provider: source, operation: :search_database_rebuild_batch) do
          source.search_database_rebuild_batch(task: task, reason: item.fetch("reason"))
        end
      end

      def mark_done(task, key, message)
        change_checkpoint(task) { task.checkpoint["#{key}_done"] = true }
        Result.new(done: false, processed: 1, failed: 0, message: message, level: "info")
      end

      def selected_entry_pending?(item)
        source = source_for(item.fetch("entity"))
        return false unless source

        if source.current_content_version.nil? && source.respond_to?(:search_database_initialize_content_version!) && source_tables(source).all? { |table| SyrusSearchDatabaseTasks.table_exists?(table) }
          source.search_database_initialize_content_version!
        end
        return true if source.current_content_version.to_s != item["target_version"].to_s

        source.search_database_integrity_repair_needed?
      end

      def selected_schema_missing?(plan)
        plan.reject { |item| item["entity"] == "schema" }.any? do |item|
          source = source_for(item["entity"])
          source && source_tables(source).any? { |table| !SyrusSearchDatabaseTasks.table_exists?(table) }
        end
      end

      def versioned_sources
        [ ChatMessageSearchIndex, OperationalLogIndex, *plugin_search_sources ].select do |source|
          (!source.respond_to?(:search_database_available?) || source.search_database_available?) &&
            source.respond_to?(:search_database_rebuild_key) &&
            source.respond_to?(:search_database_content_version) &&
            source.respond_to?(:current_content_version) &&
            source.respond_to?(:search_database_tables) &&
            source.respond_to?(:search_database_rebuild_units) &&
            source.respond_to?(:search_database_integrity_repair_needed?) &&
            source.respond_to?(:search_database_rebuild_batch)
        end.uniq { |source| source.search_database_rebuild_key.to_s }
      end

      def source_for(key) = versioned_sources.find { |source| source.search_database_rebuild_key.to_s == key.to_s }

      def source_tables(source) = Array(source.search_database_tables).map(&:to_s)

      def estimate_units(plan)
        plan.sum do |item|
          next 1 if item["entity"] == "schema"

          source = source_for(item["entity"])
          source ? [ source.search_database_rebuild_units.to_i, 1 ].max : 1
        end
      end

      def plugin_search_sources
        return [] unless defined?(Syrus::PluginRegistry)

        @plugin_search_sources ||= Syrus::PluginRegistry.providers_for("global_search:source")
      rescue StandardError
        []
      end

      def change_checkpoint(task)
        task.checkpoint_will_change!
        yield
      end
    end
  end
end
