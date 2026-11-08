module MaintenanceTasks
  module Definitions
    class ChatAttachmentBackfill < Base
      Failure = Data.define(:source, :id, :error)

      class Source
        attr_reader :key, :model

        def initialize(key, model)
          @key = key
          @model = model
        end

        def upper_bound = model.maximum(:id).to_i

        def candidate_scope(after_id:, up_to_id:)
          model.where(id: (after_id + 1)..up_to_id)
            .where("CAST(content AS CHAR) LIKE ?", '%"data"%')
            .order(:id)
        end

        def pending_count
          candidate_scope(after_id: 0, up_to_id: upper_bound).reorder(nil).find_each.count { |record| inline_data?(record) }
        end

        def inline_data?(record)
          content = record.content
          content = JSON.parse(content) if content.is_a?(String)
          Array(content.is_a?(Hash) ? content["attachments"] : nil).any? do |attachment|
            attachment.respond_to?(:to_h) && attachment.to_h.stringify_keys.key?("data")
          end
        rescue JSON::ParserError
          false
        end
      end

      SOURCES = [
        Source.new("chat_messages", ChatMessage),
        Source.new("queued_messages", ChatQueuedMessage),
        Source.new("scratchpad_items", ChatScratchpadItem)
      ].freeze
      SOURCE_BY_KEY = SOURCES.index_by(&:key).freeze
      CURSORS_KEY = "cursors".freeze
      UPPER_BOUNDS_KEY = "upper_bounds".freeze
      UNRESOLVED_KEY = "unresolved".freeze
      RETRY_QUEUE_KEY = "retry_queue".freeze
      RETRY_ACTIVE_KEY = "retry_active".freeze

      key "chat_attachment_backfill"
      title "Backfill chat file attachments"
      summary "Moves legacy inline chat attachment bytes into Active Storage and rewrites message, queue, and scratchpad JSON to stored references."
      category "backfill"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "chat_attachment_backfill"
      batch_size 100
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/chat_attachment_backfill.md")

      step "scan", "Store legacy inline attachments", "Processes Chat messages, queued messages, and scratchpad items in bounded ID batches."
      step "retry", "Retry failed records", "Retries records that could not be decoded, stored, verified, or rewritten during the first pass."

      def estimate_total_units = SOURCES.sum(&:pending_count)

      def pending_reason
        "#{estimate_total_units} chat record(s) contain legacy inline attachment data."
      end

      def build_task_attributes(**)
        super.tap do |attributes|
          attributes[:checkpoint][CURSORS_KEY] = SOURCES.to_h { |source| [ source.key, 0 ] }
          attributes[:checkpoint][UPPER_BOUNDS_KEY] = SOURCES.to_h { |source| [ source.key, source.upper_bound ] }
          attributes[:checkpoint][UNRESOLVED_KEY] = []
        end
      end

      def perform_batch(task)
        initialize_checkpoint(task)
        source = next_source(task)
        return scan_source(task, source) if source

        retry_failures(task)
      end

      private

      def initialize_checkpoint(task)
        task.checkpoint_will_change!
        task.checkpoint[CURSORS_KEY] ||= SOURCES.to_h { |source| [ source.key, 0 ] }
        task.checkpoint[UPPER_BOUNDS_KEY] ||= SOURCES.to_h { |source| [ source.key, source.upper_bound ] }
        task.checkpoint[UNRESOLVED_KEY] ||= []
      end

      def next_source(task)
        SOURCES.find do |source|
          task.checkpoint[CURSORS_KEY][source.key].to_i < task.checkpoint[UPPER_BOUNDS_KEY][source.key].to_i
        end
      end

      def scan_source(task, source)
        cursor = task.checkpoint[CURSORS_KEY][source.key].to_i
        upper_bound = task.checkpoint[UPPER_BOUNDS_KEY][source.key].to_i
        records = source.candidate_scope(after_id: cursor, up_to_id: upper_bound).limit(task.batch_size).to_a
        task.current_step_key = "scan"
        task.current_step_title = "Store legacy inline attachments"

        if records.empty?
          task.checkpoint[CURSORS_KEY][source.key] = upper_bound
          return result_for(task, processed: 0, message: I18n.t("server.maintenance_tasks.chat_attachment_backfill.finished_scanning", source: source.key.humanize.downcase))
        end

        processed = 0
        records.each do |record|
          next unless source.inline_data?(record)

          processed += 1
          migrate(record)
          remove_failure(task, source.key, record.id)
        rescue StandardError => e
          record_failure(task, source.key, record.id, e)
        end
        task.checkpoint[CURSORS_KEY][source.key] = records.last.id

        result_for(task, processed: processed, message: I18n.t("server.maintenance_tasks.chat_attachment_backfill.processed", count: processed, source: source.key.humanize.downcase))
      end

      def retry_failures(task)
        start_retry_cycle(task) unless task.checkpoint[RETRY_ACTIVE_KEY]
        queue = task.checkpoint[RETRY_QUEUE_KEY]
        if queue.empty?
          task.checkpoint[RETRY_ACTIVE_KEY] = false
          unresolved = task.checkpoint[UNRESOLVED_KEY]
          return Result.new(
            done: true,
            processed: 0,
            failed: unresolved.size,
            clear_failed_units: true,
            message: unresolved.empty? ? I18n.t("server.maintenance_tasks.chat_attachment_backfill.complete") : I18n.t("server.maintenance_tasks.chat_attachment_backfill.unresolved", count: unresolved.size),
            level: unresolved.empty? ? "info" : "warning",
            metadata: { unresolved: unresolved }
          )
        end

        task.current_step_key = "retry"
        task.current_step_title = "Retry failed records"
        queue.shift(task.batch_size).each do |failure|
          source = SOURCE_BY_KEY.fetch(failure.fetch("source"))
          record = source.model.find_by(id: failure.fetch("id"))
          next remove_failure(task, source.key, failure.fetch("id")) unless record&.then { |item| source.inline_data?(item) }

          migrate(record)
          remove_failure(task, source.key, record.id)
        rescue StandardError => e
          record_failure(task, source.key, failure.fetch("id"), e)
        end

        result_for(task, processed: 0, message: I18n.t("server.maintenance_tasks.chat_attachment_backfill.retried"))
      end

      def start_retry_cycle(task)
        task.checkpoint[RETRY_QUEUE_KEY] = task.checkpoint[UNRESOLVED_KEY].deep_dup
        task.checkpoint[UNRESOLVED_KEY] = []
        task.checkpoint[RETRY_ACTIVE_KEY] = true
      end

      def migrate(record)
        ChatAttachments::InlineBackfill.new(record).call
      end

      def record_failure(task, source, id, error)
        remove_failure(task, source, id)
        task.checkpoint[UNRESOLVED_KEY] << Failure.new(source, id, "#{error.class}: #{error.message}").to_h.stringify_keys
      end

      def remove_failure(task, source, id)
        task.checkpoint[UNRESOLVED_KEY].reject! { |failure| failure["source"] == source && failure["id"].to_i == id.to_i }
      end

      def result_for(task, processed:, message:)
        Result.new(
          done: false,
          processed: processed,
          failed: task.checkpoint[UNRESOLVED_KEY].size,
          clear_failed_units: true,
          message: message,
          level: "progress"
        )
      end
    end
  end
end
