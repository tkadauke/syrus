module ValidatesAgentProvider
  extend ActiveSupport::Concern

  class_methods do
    # Shared shape for every `agent_provider`/`provider` column that should
    # name a real agent-provider plugin. The inclusion list is
    # `User.agent_providers` -- the set of currently *enabled*
    # agent-provider plugins. A brand-new install starts with every
    # agent-provider plugin disabled (see e.g. `plugins/claude_agent`'s
    # `default_enabled: false`), so that list is legitimately empty until an
    # operator enables one from Admin -> Plugins. Validating strictly
    # against an empty list there would make it impossible to even create
    # the first User record: the column's DB default ("claude") would never
    # be "included" in []. Falling back to the record's own current value
    # when no provider is configured yet keeps bootstrapping unblocked --
    # the value is merely a placeholder until a plugin is actually enabled,
    # the same way `AgentProviders.for` already raises a clear
    # `ConfigurationError` if something tries to actually run with it.
    def validates_agent_provider(attribute = :agent_provider, allow_nil: false)
      inclusion = {
        in: ->(record) { User.agent_providers.presence || Array(record.public_send(attribute)) }
      }

      if allow_nil
        validates attribute, inclusion: inclusion, allow_nil: true
      else
        validates attribute, presence: true, inclusion: inclusion
      end
    end
  end
end
