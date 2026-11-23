module ConnectedAccounts
  # Shared plumbing for a provider that also is a named platform service on
  # the system-invocation path (see SystemInvocation). The broker injects an
  # opaque binding through `register_system_access`; the service keeps it and
  # presents it on every brokered call. Extending classes implement
  # `system_invoke(context)` and expose only narrow, fixed operations.
  module SystemServiceProvider
    def register_system_access(identity, binding)
      system_access_bindings[identity.to_s] = binding
    end

    def with_system_access(identity:, **options)
      AccountClient.with_system_access(service_binding: system_access_bindings.fetch(identity.to_s), **options)
    end

    private

    def system_access_bindings = (@system_access_bindings ||= {})
  end
end
