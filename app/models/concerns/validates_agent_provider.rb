module ValidatesAgentProvider
  extend ActiveSupport::Concern

  class_methods do
    # Shared shape for every `agent_provider`/`provider` column that should
    # name a real agent-provider plugin. Persistence accepts any installed
    # provider key, even when that plugin is currently disabled: brand-new
    # installs start with agent-provider plugins off, and rows may still carry
    # the schema default ("claude") until onboarding connects/enables the first
    # provider. Runtime paths still resolve through `User.agent_providers`, the
    # enabled-provider list, so a disabled placeholder cannot actually run.
    def validates_agent_provider(attribute = :agent_provider, allow_nil: false)
      inclusion = {
        in: ->(_record) { User.known_agent_providers }
      }

      if allow_nil
        validates attribute, inclusion: inclusion, allow_nil: true
      else
        validates attribute, presence: true, inclusion: inclusion
      end
    end
  end
end
