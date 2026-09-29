module SkipIfPending
  extend ActiveSupport::Concern

  def self.declare_metrics!
    Syrus::Metrics.declare do
      counter :skip_if_pending_skips_total, tags: %i[job_class queue mode],
              comment: "Job enqueue attempts skipped because an unfinished matching job already exists"
    end
  end
  declare_metrics!

  class_methods do
    def perform_later(*args, **kwargs)
      if (mode = pending_solid_queue_job_mode(args, kwargs))
        record_skip_if_pending_metric(mode)
        return
      end

      super
    end

    def perform_later_missing_simple_args(argument_lists)
      argument_lists = argument_lists.map { |args| Array(args) }
      return if argument_lists.empty?
      return argument_lists.each { |args| perform_later(*args) } unless argument_lists.all? { |args| simple_active_job_arguments?(args) }

      pending = pending_solid_queue_argument_sets(argument_lists)
      missing = argument_lists.reject { |args| pending.include?(args) }
      (argument_lists.size - missing.size).times { record_skip_if_pending_metric("arguments") }
      return if missing.empty?

      ActiveJob.perform_all_later(missing.map { |args| new(*args) })
    end

    private

    def pending_solid_queue_job_mode(args, kwargs)
      # Solid Queue keeps failed Jobs with finished_at unset and records their
      # terminal state in solid_queue_failed_executions. Treating every
      # unfinished row as pending permanently poisons this dedup key after the
      # first failure, so exclude terminal failures at the shared boundary.
      scope = SolidQueue::Job
        .where(class_name: name, finished_at: nil)
        .where.missing(:failed_execution)
      return "class" if args.empty? && kwargs.empty? && scope.exists?
      return false if kwargs.any?
      return false unless simple_active_job_arguments?(args)

      pending = if SolidQueue::Job.connection.adapter_name.downcase.include?("mysql")
                  scope
                    .where("JSON_UNQUOTE(JSON_EXTRACT(arguments, '$.arguments')) = ?", JSON.generate(args))
                    .exists?
      else
                  scope.limit(1_000).any? { |job| active_job_arguments(job.arguments) == args }
      end

      pending ? "arguments" : false
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      false
    end

    def pending_solid_queue_argument_sets(argument_lists)
      scope = SolidQueue::Job
        .where(class_name: name, finished_at: nil)
        .where.missing(:failed_execution)

      if SolidQueue::Job.connection.adapter_name.downcase.include?("mysql")
        serialized_args = argument_lists.map { |args| JSON.generate(args) }
        scope
          .where("JSON_UNQUOTE(JSON_EXTRACT(arguments, '$.arguments')) IN (?)", serialized_args)
          .pluck(Arel.sql("JSON_UNQUOTE(JSON_EXTRACT(arguments, '$.arguments'))"))
          .filter_map { |json| active_job_arguments({ "arguments" => JSON.parse(json) }) }
      else
        scope.limit(1_000).filter_map { |job| active_job_arguments(job.arguments) }
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      []
    end

    def record_skip_if_pending_metric(mode)
      Syrus::Metrics.counter(:syrus_skip_if_pending_skips_total).increment(
        tags: {
          job_class: name,
          queue: queue_name,
          mode: mode
        }
      )
    end

    def simple_active_job_arguments?(args)
      args.all? { |arg| arg.nil? || arg == true || arg == false || arg.is_a?(Numeric) || arg.is_a?(String) }
    end

    def active_job_arguments(arguments)
      payload = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
      args = payload.is_a?(Hash) ? (payload["arguments"] || payload[:arguments]) : payload
      args.is_a?(Array) ? args : nil
    rescue JSON::ParserError, TypeError
      nil
    end
  end
end
