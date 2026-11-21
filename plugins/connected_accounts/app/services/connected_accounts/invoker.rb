module ConnectedAccounts
  module Invoker
    EXTENSION_POINT = "connected_accounts:provider"

    module_function

    def call(provider:, capability:, context:)
      if defined?(Syrus::Host::PluginInvocation)
        Syrus::Host::PluginInvocation.call(
          extension_point: EXTENSION_POINT,
          provider: provider,
          operation: capability,
          on_decline: ->(reason) { raise ProviderCallFailed, reason.to_s }
        ) { provider.public_send(capability, context) }
      else
        provider.public_send(capability, context)
      end
    end

    ProviderCallFailed = Class.new(StandardError)
  end
end
