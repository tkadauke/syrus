require "set"

module MaintenanceTasks
  module Definitions
    class SearchDatabaseRebuild < Base
      class EntityHandler
        def initialize(definition) = @definition = definition
      end

      class ChatHandler < EntityHandler
        def call(task, item) = @definition.send(:index_chats, task, item)
      end

      class LogHandler < EntityHandler
        def call(task, _item) = @definition.send(:index_logs, task)
      end

      class PluginHandler < EntityHandler
        def call(task, item) = @definition.send(:index_plugin_source, task, item.fetch("entity"))
      end

      PLAN_KEY = "rebuild_plan"
      CORE_TABLES = { "chats" => %w[chat_message_fts chat_search_metadata], "jobs" => %w[job_fts], "epics" => %w[epic_fts], "logs" => %w[operational_log_fts] }.freeze
      ENTITY_HANDLERS = { "chats" => ChatHandler, "logs" => LogHandler }.freeze

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
        rebuild_plan.sum { |entry| entry["entity"] == "schema" ? 1 : [ units_for(entry["entity"]), 1 ].max }
      end

      def pending? = rebuild_plan.any?
      def pending_reason = pending_reason_for(rebuild_plan)

      def build_task_attributes(**arguments)
        plan = rebuild_plan
        super(**arguments).deep_merge(
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
          key = source.search_database_rebuild_key.to_s
          current = source.current_content_version&.to_s
          target = source.search_database_content_version.to_s
          reason = if source_tables(source, key).intersect?(missing)
            "missing_schema"
          elsif current != target
            "version_mismatch"
          elsif integrity_repair_needed?(source, key)
            "integrity_repair"
          end
          plan << entry(key, current, target, reason) if reason
        end
        plan
      rescue StandardError
        [ entry("schema", nil, nil, "missing_schema") ]
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
        ENTITY_HANDLERS.fetch(item.fetch("entity"), PluginHandler).new(self).call(task, item)
      end

      def index_chats(task, item)
        task.current_step_key = "chats"
        task.current_step_title = "Index chat messages"
        if item["reason"] == "version_mismatch" && !task.checkpoint["chats_prepared"]
          ChatMessageSearchIndex.prepare_content_version!
          change_checkpoint(task) do
            task.checkpoint["chats_prepared"] = true
            task.checkpoint["last_chat_message_id"] = 0
          end
        end
        processed = 0
        chat_scope.order(:id).where("id > ?", task.checkpoint["last_chat_message_id"].to_i).limit(SearchIndexWriteLimits.clamp_rows(task.batch_size)).find_each do |message|
          change_checkpoint(task) { task.checkpoint["last_chat_message_id"] = message.id }
          processed += 1
          ChatMessageSearchIndex.insert(message) if ChatMessageSearchIndex.indexable?(message) && !ChatMessageSearchIndex.indexed?(message.id)
        end
        done = processed.zero? || task.checkpoint["last_chat_message_id"].to_i >= ChatMessage.maximum(:id).to_i
        if done
          ChatMessageSearchIndex.finish_content_version!
          change_checkpoint(task) { task.checkpoint["chats_done"] = true }
        end
        Result.new(done: false, processed: processed.nonzero? || (done ? 1 : 0), failed: 0, message: "Indexed #{processed} chat message(s).", level: "progress", metadata: { "entity" => "chats", "current_version" => item["current_version"], "target_version" => item["target_version"] })
      end

      def index_logs(task)
        task.current_step_key = "logs"
        task.current_step_title = "Index operational logs"
        return mark_done(task, "logs", "Operational log index is not enabled.") unless OperationalLogging.configured_for_instance?

        ids = OperationalLogEvent.order(:id).where("id > ?", task.checkpoint["last_operational_log_id"].to_i).limit(SearchIndexWriteLimits.clamp_rows(task.batch_size)).pluck(:id)
        IndexOperationalLogEventsJob.perform_now(ids)
        done = ids.empty? || ids.last.to_i >= OperationalLogEvent.maximum(:id).to_i
        change_checkpoint(task) do
          task.checkpoint["last_operational_log_id"] = ids.last if ids.any?
          task.checkpoint["logs_done"] = true if done
        end
        OperationalLogIndex.finish_content_version! if done
        Result.new(done: false, processed: ids.size.nonzero? || (done ? 1 : 0), failed: 0, message: "Indexed #{ids.size} operational log event(s).", level: "progress")
      end

      def index_plugin_source(task, key)
        source = source_for(key)
        return mark_done(task, key, "#{key.humanize} index is unavailable.") unless source&.respond_to?(:search_database_rebuild_batch)

        PerformanceLogging.plugin_call(extension_point: "global_search:source", provider: source, operation: :search_database_rebuild_batch) { source.search_database_rebuild_batch(task: task) }
      end

      def mark_done(task, key, message)
        change_checkpoint(task) { task.checkpoint["#{key}_done"] = true }
        Result.new(done: false, processed: 1, failed: 0, message: message, level: "info")
      end

      def selected_entry_pending?(item)
        source = source_for(item.fetch("entity"))
        return false unless source
        return true if source.current_content_version.to_s != item["target_version"].to_s

        integrity_repair_needed?(source, item.fetch("entity"))
      rescue StandardError
        true
      end

      def selected_schema_missing?(plan)
        plan.reject { |item| item["entity"] == "schema" }.any? do |item|
          source_tables(source_for(item["entity"]), item["entity"]).any? { |table| !SyrusSearchDatabaseTasks.table_exists?(table) }
        end
      end

      def integrity_repair_needed?(source, key)
        return source.search_database_rebuild_pending? if source.respond_to?(:search_database_rebuild_pending?)
        return missing_chat_messages_count.positive? if key == "chats"
        return OperationalLogging.configured_for_instance? && indexed_count("operational_log_fts", "operational_log_event_id") < OperationalLogEvent.count if key == "logs"

        false
      end

      def versioned_sources
        [ ChatMessageSearchIndex, OperationalLogIndex, *plugin_search_sources ].select do |source|
          source.respond_to?(:search_database_rebuild_key) && source.respond_to?(:search_database_content_version) && source.respond_to?(:current_content_version)
        end.uniq { |source| source.search_database_rebuild_key.to_s }
      end

      def source_for(key) = versioned_sources.find { |source| source.search_database_rebuild_key.to_s == key.to_s }

      def source_tables(source, key)
        return Array(source.search_tables).to_h.keys.map(&:to_s) if source&.respond_to?(:search_tables)

        CORE_TABLES.fetch(key.to_s, [])
      end

      def units_for(key)
        source = source_for(key)
        return chat_scope.count if key == "chats"
        return OperationalLogging.configured_for_instance? ? OperationalLogEvent.count : 0 if key == "logs"

        source&.respond_to?(:search_database_rebuild_units) ? source.search_database_rebuild_units.to_i : 0
      end

      def missing_chat_messages_count
        return chat_scope.count unless SyrusSearchDatabaseTasks.table_exists?("chat_search_metadata")

        indexed = SearchRecord.connection.select_values("SELECT key FROM chat_search_metadata WHERE key LIKE 'indexed_chat_message:%'").map { |key| key.delete_prefix("indexed_chat_message:").to_i }.to_set
        chat_scope.find_each.count { |message| ChatMessageSearchIndex.indexable?(message) && !indexed.include?(message.id) }
      end

      def chat_scope = ChatMessage.where(role: %w[user assistant]).where.not(content: [ nil, "" ])

      def indexed_count(table, column)
        return 0 unless SyrusSearchDatabaseTasks.table_exists?(table)

        SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{column}) FROM #{table}").to_i
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
