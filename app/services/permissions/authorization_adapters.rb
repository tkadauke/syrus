module Permissions
  # Resolves optional domain behavior for a pending authorization action.
  # Only enabled, healthy permission providers participate because
  # PluginRegistry owns provider lifecycle filtering.
  class AuthorizationAdapters
    class DuplicateAction < ArgumentError; end

    def self.resolve(action)
      return if action.blank?

      matches = adapters.filter_map { |registered_action, adapter| adapter if registered_action == action.to_s }
      raise DuplicateAction, "authorization action #{action.inspect} is registered by more than one provider" if matches.many?

      matches.first
    end

    def self.adapters
      Syrus::Plugin::Toolkit.permission_providers.flat_map do |provider|
        next [] unless provider.respond_to?(:permission_authorization_adapters)

        result = Syrus::PluginInvocation.call(
          extension_point: :permission_provider, provider:, operation: :permission_authorization_adapters,
          on_decline: []
        ) { provider.permission_authorization_adapters.to_a }
        if result.is_a?(Syrus::PluginInvocation::Failed)
          Rails.logger.warn(
            "[Permissions::AuthorizationAdapters] provider inventory unavailable: " \
            "#{result.exception_class}: #{result.message}"
          )
        end
        Syrus::PluginInvocation.value(result)
      end
    end
    private_class_method :adapters
  end
end
