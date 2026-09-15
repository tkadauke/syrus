# frozen_string_literal: true

module WorkEngine
  module Simulation
    module SolidQueueBootstrap
      TABLES = %i[
        solid_queue_recurring_executions
        solid_queue_scheduled_executions
        solid_queue_ready_executions
        solid_queue_claimed_executions
        solid_queue_blocked_executions
        solid_queue_failed_executions
        solid_queue_pauses
        solid_queue_jobs
        solid_queue_processes
        solid_queue_recurring_tasks
        solid_queue_semaphores
      ].freeze

      MODELS = [
        SolidQueue::Job,
        SolidQueue::BlockedExecution,
        SolidQueue::ClaimedExecution,
        SolidQueue::FailedExecution,
        SolidQueue::Pause,
        SolidQueue::Process,
        SolidQueue::ReadyExecution,
        SolidQueue::RecurringExecution,
        SolidQueue::RecurringTask,
        SolidQueue::ScheduledExecution,
        SolidQueue::Semaphore
      ].freeze

      module_function

      def ensure!
        return unless Rails.env.test?

        load_queue_schema! unless all_tables_exist?
        reset_columns!
      end

      def clear!
        return unless Rails.env.test?

        ensure!
        connection = ActiveRecord::Base.connection
        TABLES.each do |table|
          next unless connection.table_exists?(table)

          connection.delete("DELETE FROM #{connection.quote_table_name(table)}")
        end
      end

      def all_tables_exist?
        connection = ActiveRecord::Base.connection
        TABLES.all? { |table| connection.table_exists?(table) }
      end

      def load_queue_schema!
        drop_existing_tables!
        old_verbose = ActiveRecord::Schema.verbose
        ActiveRecord::Schema.verbose = false
        load Rails.root.join("db/queue_schema.rb")
      ensure
        ActiveRecord::Schema.verbose = old_verbose
      end

      def reset_columns!
        MODELS.each(&:reset_column_information)
      end

      def drop_existing_tables!
        connection = ActiveRecord::Base.connection
        connection.disable_referential_integrity do
          TABLES.each do |table|
            connection.drop_table(table, if_exists: true)
          end
        end
      end
    end
  end
end
