module Permissions
  # Compatibility entry point for plugin callers. Core controllers use the
  # actor-neutral decision engine directly.
  class CoworkerAuthorizationDecision < Syrus::Host::PermissionAuthorizationDecision
  end
end
