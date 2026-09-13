require "set"

module MaintenanceTasks
  module Definitions
    class SearchDatabaseRebuild < Base
      key "search_database_rebuild"
      title "Rebuild search database"
      summary "Creates missing search tables and backfills searchable chats, jobs, epics, logs, and plugin-provided search sources."
      category "index"
      recurrence "repeatable"
      required_role "admin"
      concurrency_key "search_database_rebuild"
      batch_size 250
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/search_database_rebuild.md")

      step "schema", "Prepare search schema", "Creates or repairs the local SQLite FTS tables used by global search."
      step "chats", "Index chat messages", "Indexes searchable user and assistant chat messages."
      step "jobs", "Index jobs", "Indexes job titles, descriptions, and summaries when Global Search is installed."
      step "epics", "Index epics", "Indexes epic titles and descriptions when Global Search is installed."
      step "logs", "Index operational logs", "Indexes operational logs when instance logging is configured."

      def estimate_total_units
        1 + chat_messages_count + jobs_count + epics_count + operational_logs_count
      end

      def pending?
        search_database_needs_prepare? || missing_chat_messages_count.positive? || jobs_need_rebuild? || epics_need_rebuild? || operational_logs_need_rebuild?
      end

      def pending_reason
        "Search database schema or indexed rows are missing/stale."
      end

      def perform_batch(task)
        unless task.checkpoint["schema_prepared"]
          return prepare_schema(task)
        end

        if missing_chat_messages_count.positive?
          return index_chat_messages(task)
        end

        if jobs_need_rebuild?
          return index_jobs(task)
        end

        if epics_need_rebuild?
          return index_epics(task)
        end

        if operational_logs_need_rebuild?
          return index_operational_logs(task)
        end

        Result.new(done: true, processed: 0, failed: 0, message: "Search database rebuild is complete.", level: "info")
      end

      private

      def prepare_schema(task)
        task.current_step_key = "schema"
        task.current_step_title = "Prepare search schema"
        SyrusSearchDatabaseTasks.prepare!
        task.checkpoint_will_change!
        task.checkpoint["schema_prepared"] = true
        Result.new(done: false, processed: 1, failed: 0, message: "Prepared search database schema.", level: "progress")
      end

      def index_chat_messages(task)
        task.current_step_key = "chats"
        task.current_step_title = "Index chat messages"

        processed = 0
        ChatMessage.order(:id).where("id > ?", task.checkpoint["last_chat_message_id"].to_i).limit(task.batch_size).find_each do |message|
          task.checkpoint_will_change!
          task.checkpoint["last_chat_message_id"] = message.id
          processed += 1
          next unless ChatMessageSearchIndex.indexable?(message)
          next if ChatMessageSearchIndex.indexed?(message.id)

          ChatMessageSearchIndex.insert(message)
        end
        task.checkpoint_will_change!
        task.checkpoint["chats_done"] = true if processed.zero? || task.checkpoint["last_chat_message_id"].to_i >= ChatMessage.maximum(:id).to_i

        Result.new(done: false, processed: processed, failed: 0, message: "Indexed #{processed} chat message(s).", level: "progress")
      end

      def index_jobs(task)
        provider = search_rebuild_provider("jobs")
        return mark_plugin_step_done(task, "jobs") unless provider

        task.current_step_key = "jobs"
        task.current_step_title = "Index jobs"
        index_search_records(task, provider: provider, checkpoint_key: "last_job_id", done_key: "jobs_done", message_label: "job")
      end

      def index_epics(task)
        provider = search_rebuild_provider("epics")
        return mark_plugin_step_done(task, "epics") unless provider

        task.current_step_key = "epics"
        task.current_step_title = "Index epics"
        index_search_records(task, provider: provider, checkpoint_key: "last_epic_id", done_key: "epics_done", message_label: "epic")
      end

      def index_search_records(task, provider:, checkpoint_key:, done_key:, message_label:)
        processed = 0
        scope = provider.search_rebuild_scope
        scope.where("id > ?", task.checkpoint[checkpoint_key].to_i).limit(task.batch_size).find_each do |record|
          provider.index_search_record(record)
          task.checkpoint_will_change!
          task.checkpoint[checkpoint_key] = record.id
          processed += 1
        end
        task.checkpoint_will_change!
        task.checkpoint[done_key] = true if processed.zero? || task.checkpoint[checkpoint_key].to_i >= scope.maximum(:id).to_i

        Result.new(done: false, processed: processed, failed: 0, message: "Indexed #{processed} #{message_label}(s).", level: "progress")
      end

      def index_operational_logs(task)
        task.current_step_key = "logs"
        task.current_step_title = "Index operational logs"
        return mark_plugin_step_done(task, "logs") unless OperationalLogging.configured_for_instance?

        ids = OperationalLogEvent.order(:id).where("id > ?", task.checkpoint["last_operational_log_id"].to_i).limit(task.batch_size).pluck(:id)
        IndexOperationalLogEventsJob.perform_now(ids)
        task.checkpoint_will_change!
        task.checkpoint["last_operational_log_id"] = ids.last if ids.any?
        task.checkpoint["logs_done"] = true if ids.empty? || ids.last.to_i >= OperationalLogEvent.maximum(:id).to_i

        Result.new(done: false, processed: ids.size, failed: 0, message: "Indexed #{ids.size} operational log event(s).", level: "progress")
      end

      def mark_plugin_step_done(task, step)
        task.checkpoint_will_change!
        task.checkpoint["#{step}_done"] = true
        Result.new(done: false, processed: 0, failed: 0, message: "#{step.humanize} index is not available in this installation.", level: "info")
      end

      def search_database_needs_prepare?
        SyrusSearchDatabaseTasks.required_table_sql.keys.any? { |table| !SyrusSearchDatabaseTasks.table_exists?(table) }
      rescue StandardError
        true
      end

      def missing_chat_messages_count
        return chat_message_scope.count unless SyrusSearchDatabaseTasks.table_exists?("chat_search_metadata")

        indexed_ids = indexed_chat_message_ids.map(&:to_i).to_set
        chat_message_scope.find_each.count do |message|
          ChatMessageSearchIndex.indexable?(message) && !indexed_ids.include?(message.id)
        end
      rescue StandardError
        chat_message_scope.count
      end

      def chat_message_scope
        ChatMessage.where(role: %w[user assistant]).where.not(content: [ nil, "" ])
      end

      def indexed_chat_message_ids
        SearchRecord.connection.select_values(
          "SELECT CAST(SUBSTR(key, ?) AS INTEGER) FROM chat_search_metadata WHERE key LIKE ?",
          "MaintenanceTasks::SearchDatabaseRebuild Indexed Chat Messages",
          [
            bind(ChatMessageSearchIndex::INDEXED_MESSAGE_KEY_PREFIX.length + 1),
            bind("#{ChatMessageSearchIndex::INDEXED_MESSAGE_KEY_PREFIX}%")
          ]
        )
      end

      def jobs_need_rebuild?
        (provider = search_rebuild_provider("jobs")) && indexed_count("job_fts", "job_id") < provider.search_rebuild_scope.count
      rescue StandardError
        search_rebuild_provider("jobs")&.search_rebuild_scope&.exists? || false
      end

      def epics_need_rebuild?
        (provider = search_rebuild_provider("epics")) && indexed_count("epic_fts", "epic_id") < provider.search_rebuild_scope.count
      rescue StandardError
        search_rebuild_provider("epics")&.search_rebuild_scope&.exists? || false
      end

      def operational_logs_need_rebuild?
        OperationalLogging.configured_for_instance? && indexed_count("operational_log_fts", "operational_log_event_id") < OperationalLogEvent.count
      rescue StandardError
        OperationalLogging.configured_for_instance? && OperationalLogEvent.exists?
      end

      def indexed_count(table, id_column)
        return 0 unless SyrusSearchDatabaseTasks.table_exists?(table)

        SearchRecord.connection.select_value("SELECT COUNT(DISTINCT #{id_column}) FROM #{table}").to_i
      end

      def chat_messages_count = chat_message_scope.count
      def jobs_count = search_rebuild_provider("jobs")&.search_rebuild_scope&.count || 0
      def epics_count = search_rebuild_provider("epics")&.search_rebuild_scope&.count || 0
      def operational_logs_count = OperationalLogging.configured_for_instance? ? OperationalLogEvent.count : 0

      def search_rebuild_provider(key)
        return nil unless defined?(Syrus::PluginRegistry)

        Syrus::PluginRegistry.providers_for("global_search:source").find do |provider|
          provider.respond_to?(:search_rebuild_key) &&
            provider.respond_to?(:search_rebuild_scope) &&
            provider.respond_to?(:index_search_record) &&
            provider.search_rebuild_key.to_s == key.to_s
        end
      rescue StandardError
        nil
      end

      def bind(value)
        ActiveRecord::Relation::QueryAttribute.new(nil, value, ActiveRecord::Type::Value.new)
      end
    end
  end
end
