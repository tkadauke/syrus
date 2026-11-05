module Permissions
  # Actor-neutral entry point for resolving authorization requests. The
  # compatibility superclass retains the established transaction and
  # exactly-once invocation semantics while callers migrate names.
  class AuthorizationDecision < CoworkerAuthorizationDecision
  end
end
