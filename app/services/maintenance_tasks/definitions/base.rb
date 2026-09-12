module MaintenanceTasks
  module Definitions
    class Base
      Step = Data.define(:key, :title, :description)
      Result = Struct.new(:done, :processed, :failed, :message, :level, keyword_init: true)

      class_attribute :definition_key, :definition_title, :definition_summary,
                      :definition_category, :definition_recurrence,
                      :definition_required_role, :definition_concurrency_key,
                      :definition_batch_size, :definition_max_parallelism,
                      :definition_steps, :definition_documentation_path

      self.definition_category = "backfill"
      self.definition_recurrence = "one_off"
      self.definition_required_role = "admin"
      self.definition_batch_size = 250
      self.definition_max_parallelism = 1
      self.definition_steps = []

      class << self
        def key(value) = self.definition_key = value.to_s
        def title(value) = self.definition_title = value.to_s
        def summary(value) = self.definition_summary = value.to_s
        def category(value) = self.definition_category = value.to_s
        def recurrence(value) = self.definition_recurrence = value.to_s
        def required_role(value) = self.definition_required_role = value.to_s
        def concurrency_key(value) = self.definition_concurrency_key = value.to_s
        def batch_size(value) = self.definition_batch_size = value.to_i
        def max_parallelism(value) = self.definition_max_parallelism = value.to_i
        def documentation_path(value) = self.definition_documentation_path = value.to_s

        def step(key, title, description = nil)
          self.definition_steps += [ Step.new(key.to_s, title.to_s, description.to_s.presence) ]
        end
      end

      def key = definition_key
      def title = definition_title
      def summary = definition_summary
      def category = definition_category
      def recurrence = definition_recurrence
      def required_role = definition_required_role
      def concurrency_key = definition_concurrency_key.presence || key
      def batch_size = definition_batch_size
      def max_parallelism = definition_max_parallelism
      def steps = definition_steps

      def documentation
        path = definition_documentation_path
        return "" if path.blank? || !File.exist?(path)

        File.read(path)
      end

      def pending? = estimate_total_units.positive?
      def pending_reason = "#{estimate_total_units} item(s) need maintenance."

      def estimate_total_units
        raise NotImplementedError
      end

      def perform_batch(_task)
        raise NotImplementedError
      end

      def build_task_attributes(trigger_kind:, trigger_key:, task_key:, requested_by: nil)
        {
          definition_key: key,
          task_key: task_key,
          recurrence: recurrence,
          category: category,
          title: title,
          summary: summary,
          trigger_kind: trigger_kind.to_s,
          trigger_key: trigger_key.to_s,
          required_role: required_role,
          concurrency_key: concurrency_key,
          batch_size: batch_size,
          max_parallelism: max_parallelism,
          requested_by_user: requested_by,
          total_units: estimate_total_units,
          checkpoint: {},
          metadata: { "pending_reason" => pending_reason }
        }
      end
    end
  end
end
