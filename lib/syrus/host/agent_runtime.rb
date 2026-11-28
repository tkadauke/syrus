module Syrus
  module Host
    # Limits and environment defaults that agent-provider plugins share when
    # they launch an agent CLI. Reads core values on every call; it does not
    # expose the invocation engine itself.
    module AgentRuntime
      class << self
        def default_timeout_seconds = AgentInvocation::DEFAULT_TIMEOUT_SECONDS

        def silent_timeout_seconds = AgentInvocation::SILENT_TIMEOUT_SECONDS

        def default_max_turns = AgentInvocation::DEFAULT_MAX_TURNS

        def max_event_bytes = AgentInvocation::MAX_EVENT_BYTES

        def forwarded_env_keys = AgentInvocation::ENV_FORWARD

        def oversized_event_handler(provider) = AgentInvocation.oversized_event_handler(provider)

        # The execution workload policy chat agents run under, per the current setting.
        def chat_workload_policy(**) = Execution::ChatWorkloadPolicy.for_current_setting(**)

        # Cross-worker termination is a durable database request; the process
        # owner observes it and terminates the local process group.
        def terminate_chat_processes(chat_session_ids:, reason:, runtime_image_digest:)
          raise ArgumentError, "runtime_image_digest is required" if runtime_image_digest.blank?

          ids = Array(chat_session_ids).map(&:to_i).uniq
          return 0 if ids.empty?

          now = Time.current
          scope = SpawnedProcess.live_agent.where(chat_session_id: ids, kill_requested_at: nil)
          scope = scope.where("json_extract(resource_attribution, '$.runtime_image_digest') = ?", runtime_image_digest)
          count = scope.update_all(kill_requested_at: now, updated_at: now)
          OperationalLogging.ingest(level: "warn", source: "agent_runtime",
                                    message: "chat processes terminated for revoked runtime image",
                                    context: { reason:, chat_session_ids: ids, runtime_image_digest:, count: })
          count
        end
      end
    end
  end
end
