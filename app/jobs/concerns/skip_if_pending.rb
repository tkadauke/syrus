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

    private

    def pending_solid_queue_job_mode(args, kwargs)
      scope = SolidQueue::Job.where(class_name: name, finished_at: nil)
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
