module Mcp
  # Coworkers share the ordinary chat-agent tool surface. This policy names
  # the few context boundaries that registration must preserve; authorization
  # remains the responsibility of the canonical permission descriptor.
  class CoworkerToolExposure
    EXCLUDED_PLUGIN_PROVIDERS = %w[
      AdminMysql::ChatToolSet
      SyrusBrowser::ChatToolSet
    ].freeze

    # These providers contribute tools specifically for a coworker's own
    # runtime rather than inheriting an ordinary planning-chat surface.
    COWORKER_ONLY_PLUGIN_PROVIDERS = %w[
      Coworkers::ChatToolSet
      SyrusDev::ChatToolSet
    ].freeze

    DEDICATED_CHAT_ROLES = [
      AgentRole::CHAT_CODING,
      AgentRole::CHAT_LOCAL,
      AgentRole::CHAT_EVALUATOR
    ].freeze

    WORKFLOW_ROLE_TOOL_NAMES = %w[
      submit_summary
      submit_test_plan
      submit_report
      patch_workflow
      submit_adversarial_review
      submit_security_review
      submit_visual_review
      submit_coworker_review
    ].freeze

    class << self
      def core_entry?(entry)
        !entry.admin_only &&
          (entry.required_roles & DEDICATED_CHAT_ROLES).empty? &&
          !WORKFLOW_ROLE_TOOL_NAMES.include?(entry.tool_name)
      end

      def plugin_provider?(provider)
        !EXCLUDED_PLUGIN_PROVIDERS.include?(provider.name)
      end

      def plugin_provider_available?(provider, chat_session, tier:)
        return false unless plugin_provider?(provider)
        return provider.available_for?(chat_session, tier:) unless COWORKER_ONLY_PLUGIN_PROVIDERS.include?(provider.name)

        provider.available_for_coworker?(chat_session, tier:)
      end

      def plugin_definition?(definition)
        !(definition[:admin_only] || definition["admin_only"] ||
          definition[:coworker_excluded] || definition["coworker_excluded"])
      end
    end
  end
end
