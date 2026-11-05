module Permissions
  # Actor-neutral name for proactive self-requests. Coworker-specific safety
  # constraints remain enforced by the compatibility implementation.
  class PermissionRequest < CoworkerPermissionRequest
  end
end
