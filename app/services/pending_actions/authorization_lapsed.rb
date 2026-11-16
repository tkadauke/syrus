module PendingActions
  # The request was overtaken before anyone confirmed it -- the invocation was
  # withdrawn or expired, its turn ended, or its authority no longer holds. It
  # was withdrawn, not attempted: ChatPendingAction#fail_confirmation! records
  # it as cancelled rather than failed.
  class AuthorizationLapsed < ArgumentError; end
end
