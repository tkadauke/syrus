module Permissions
  # Actor-neutral entry point for authorization decisions. Domain plugins may
  # supply an adapter for their namespaced pending-action kind; the durable
  # request, lease, invocation, replay, and audit machinery remains in core.
  class AuthorizationDecision < CoworkerAuthorizationDecision
    private

    def authorization_adapter
      @authorization_adapter ||= AuthorizationAdapters.resolve(request.action)
    end

    def permission_descriptor
      return authorization_adapter.permission_descriptor(request) if authorization_adapter

      super
    end

    def subject_selector
      return authorization_adapter.subject_selector(request) if authorization_adapter

      super
    end
  end
end
