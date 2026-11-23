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
      end
    end
  end
end
