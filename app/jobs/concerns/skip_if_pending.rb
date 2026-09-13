module SkipIfPending
  extend ActiveSupport::Concern

  class_methods do
    def perform_later(*args, **kwargs)
      return if pending_solid_queue_job?(args, kwargs)

      super
    end

    private

    def pending_solid_queue_job?(args, kwargs)
      scope = SolidQueue::Job.where(class_name: name, finished_at: nil)
      return scope.exists? if args.empty? && kwargs.empty?
      return false if kwargs.any?
      return false unless simple_active_job_arguments?(args)

      if SolidQueue::Job.connection.adapter_name.downcase.include?("mysql")
        scope
          .where("JSON_UNQUOTE(JSON_EXTRACT(arguments, '$.arguments')) = ?", JSON.generate(args))
          .exists?
      else
        scope.limit(1_000).any? { |job| active_job_arguments(job.arguments) == args }
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      false
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
