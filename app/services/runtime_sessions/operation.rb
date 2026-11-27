require "securerandom"

module RuntimeSessions
  # Gives provider operations a durable, bounded lifecycle without assuming
  # that the MCP/HTTP connection outlives the provider call. The provider may
  # finish after the caller's wait budget; that late result is still recorded.
  class Operation
    DEFAULT_TIMEOUT = 45.seconds
    LOG_LIMIT = 100

    Result = Data.define(:status, :value, :error) do
      def succeeded? = status == :succeeded
      def timed_out? = status == :timed_out
    end

    def self.current(session)
      session.metadata.fetch("runtime_operation", nil)
    end

    def self.logs(session)
      Array(session.metadata["runtime_operation_logs"])
    end

    def self.reconcile_expired!(session)
      lease_id = nil
      operation = nil

      session.with_lock do
        session.reload
        operation = current(session)
        next unless operation&.fetch("state", nil) == "active" && deadline_elapsed?(operation)

        kind = operation.fetch("kind", "runtime")
        message = "#{kind} provider operation exceeded its durable deadline"
        operation = operation.merge(
          "state" => "timed_out",
          "completed_at" => Time.current.iso8601,
          "outcome" => "retryable_timeout",
          "error" => message
        )
        metadata = session.metadata.deep_dup
        logs = Array(metadata["runtime_operation_logs"]).last(LOG_LIMIT - 1)
        logs << { "at" => Time.current.iso8601, "operation_id" => operation.fetch("id"), "message" => "#{message}; the existing session remains retryable" }
        metadata["runtime_operation"] = operation
        metadata["runtime_operation_logs"] = logs
        session.update!(metadata: metadata, state: "failed", last_error: message)
        lease_id = operation["lease_id"]
      end

      release_lease(session, lease_id)
      operation
    end

    def self.deadline_elapsed?(operation)
      deadline = operation["deadline_at"]
      deadline.blank? || Time.iso8601(deadline) <= Time.current
    rescue ArgumentError
      true
    end

    def self.release_lease(session, lease_id)
      return if lease_id.blank?

      lease = session.runtime_control_leases.find_by(id: lease_id)
      lease&.release! if lease&.state == "active"
    end
    private_class_method :deadline_elapsed?, :release_lease

    def initialize(session:, kind:, timeout: DEFAULT_TIMEOUT, lease: nil)
      @session = session
      @kind = kind.to_s
      @timeout = timeout
      @lease = lease
    end

    def call(&provider_call)
      operation = begin_operation!
      queue = Queue.new
      thread = Thread.new do
        queue << [ :succeeded, provider_call.call ]
      rescue Exception => error # rubocop:disable Lint/RescueException
        queue << [ :failed, error ]
      ensure
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end

      if thread.join(@timeout)
        status, value = queue.pop
        return finish(operation, status, value, late: false)
      end

      mark_timed_out!(operation)
      Thread.new do
        thread.join
        status, value = queue.pop
        ActiveRecord::Base.connection_pool.with_connection { finish(operation, status, value, late: true) }
      end
      Result.new(status: :timed_out, value: nil, error: timeout_message)
    ensure
      release_lease!
    end

    private

    def begin_operation!
      now = Time.current
      operation = {
        "id" => SecureRandom.uuid,
        "kind" => @kind,
        "state" => "active",
        "started_at" => now.iso8601,
        "deadline_at" => (now + @timeout).iso8601,
        "lease_id" => @lease&.id
      }.compact
      persist(operation, "#{@kind} provider operation started")
      operation
    end

    def mark_timed_out!(operation)
      operation = operation.merge(
        "state" => "timed_out",
        "completed_at" => Time.current.iso8601,
        "outcome" => "retryable_timeout",
        "error" => timeout_message
      )
      persist(operation, "#{@kind} provider operation timed out; the existing session remains retryable", state: "failed", error: timeout_message, require_current: true)
    end

    def finish(operation, status, value, late:)
      if late
        @session.reload
        current_id = self.class.current(@session)&.fetch("id", nil)
        return Result.new(status: status, value: status == :succeeded ? value : nil, error: status == :failed ? value : nil) if current_id != operation.fetch("id")
      end

      if status == :succeeded
        outcome = late ? "late_succeeded" : "succeeded"
        completed = operation.merge("state" => "completed", "completed_at" => Time.current.iso8601, "outcome" => outcome)
        persist(completed, "#{@kind} provider operation #{outcome.tr('_', ' ')}", state: "running", error: nil, result: value, require_current: true)
        Result.new(status: :succeeded, value: value, error: nil)
      else
        error = value
        message = "#{error.class}: #{error.message}"
        outcome = late ? "late_failed" : "failed"
        completed = operation.merge("state" => "completed", "completed_at" => Time.current.iso8601, "outcome" => outcome, "error" => message)
        persist(completed, "#{@kind} provider operation #{outcome.tr('_', ' ')}: #{message}", state: "failed", error: message, require_current: true)
        Result.new(status: :failed, value: nil, error: error)
      end
    rescue ActiveRecord::RecordNotFound
      Result.new(status: status, value: value, error: status == :failed ? value : nil)
    end

    def persist(operation, log_message, state: nil, error: :unchanged, result: nil, require_current: false)
      @session.with_lock do
        @session.reload
        metadata = @session.metadata.deep_dup
        next false if require_current && metadata.dig("runtime_operation", "id") != operation.fetch("id")

        logs = Array(metadata["runtime_operation_logs"]).last(LOG_LIMIT - 1)
        logs << { "at" => Time.current.iso8601, "operation_id" => operation.fetch("id"), "message" => log_message }
        metadata["runtime_operation"] = operation
        metadata["runtime_operation_logs"] = logs
        metadata.merge!(result.to_h.deep_stringify_keys) if result.respond_to?(:to_h)
        attributes = { metadata: metadata }
        attributes[:state] = state if state
        attributes[:last_error] = error unless error == :unchanged
        @session.update!(attributes)
        true
      end
    end

    def timeout_message
      "#{@kind} provider operation timed out after #{@timeout.to_f.round(3)}s"
    end

    def release_lease!
      @lease&.reload
      @lease&.release! if @lease&.state == "active"
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end
end
