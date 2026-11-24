module Mcp
  # Coworkers share the ordinary chat-agent tool surface. Discovery parity is
  # an invariant: the only tools a coworker does not see are the reviewed
  # exceptions in Mcp::ChatToolParity, each with a reason code, explanation,
  # owner, and test. Authorization remains the responsibility of the
  # canonical permission descriptor, operator identity (`user.admin?`), grants,
  # and resource access -- never coworker identity.
  class CoworkerToolExposure
    LEGACY_DEFINITION_KEYS = %w[coworker_excluded].freeze

    class << self
      # An ordinary chat registry entry is shared with coworkers unless a
      # reviewed exception covers it. Admin-only entries are shared too; the
      # registry applies `context.user.admin?` to the coworker's owner.
      def core_entry?(entry)
        exception = Mcp::ChatToolParity.core_exception_for(entry)
        exception.nil? || !exception.absent_from.include?(:coworker)
      end

      # A provider is offered to coworkers unless it declares a reviewed
      # `coworker_exception` (a hash with reason_code, explanation, owner and
      # test_ref). Boolean `coworker_excluded?` is no longer supported.
      def plugin_provider?(provider)
        reject_legacy_provider_api!(provider)
        return true unless provider.respond_to?(:coworker_exception)

        exception = provider.coworker_exception
        return true if exception.nil?

        Mcp::ChatToolParity::ReviewedException.coerce(exception)
        false
      end

      def plugin_provider_available?(provider, chat_session, tier:)
        return false unless plugin_provider?(provider)

        coworker_only = coworker_only_exception(provider)
        return provider.available_for_coworker?(chat_session, tier:) if coworker_only
        provider.available_for?(chat_session, tier:)
      end

      # Returns the validated reviewed exception justifying a provider whose
      # surface exists only for coworkers, or nil.
      def coworker_only_exception(provider)
        return nil unless provider.respond_to?(:coworker_only_surface)

        exception = provider.coworker_only_surface
        exception && Mcp::ChatToolParity::ReviewedException.coerce(exception)
      end

      # +user+ gates `admin_only` definitions exactly as for ordinary chats.
      def plugin_definition?(definition, user: nil)
        reject_legacy_definition!(definition)
        if (exception = definition[:coworker_exception] || definition["coworker_exception"])
          Mcp::ChatToolParity::ReviewedException.coerce(exception)
          return false
        end
        return true unless definition[:admin_only] || definition["admin_only"]

        user.respond_to?(:admin?) && user.admin?
      end

      private

      def reject_legacy_provider_api!(provider)
        return unless provider.respond_to?(:coworker_excluded?) || provider.respond_to?(:coworker_specific_availability?)

        raise ArgumentError, "#{provider} uses a removed boolean coworker exclusion API; declare " \
          "`coworker_exception` / `coworker_only_surface` with reason_code, explanation, owner and test_ref"
      end

      def reject_legacy_definition!(definition)
        return unless LEGACY_DEFINITION_KEYS.any? { |key| definition[key.to_sym] || definition[key] }

        raise ArgumentError, "definition #{definition[:name] || definition['name']} uses removed `coworker_excluded`; " \
          "declare `coworker_exception` with reason_code, explanation, owner and test_ref"
      end
    end
  end
end
