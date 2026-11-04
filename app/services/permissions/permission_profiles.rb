require_dependency "permissions/permission_profile"

module Permissions
  module PermissionProfiles
    FULL_ACCESS = PermissionProfile.new(
      key: "full_access@v1", label: "Full access",
      description: "Allow every eligible delegable capability, subject to authorization and safety ceilings."
    ) do |descriptor, role|
      descriptor.maximum_autonomy == :none ? descriptor.defaults.fetch(role, :deny) : :allow
    end

    ASK_ON_FIRST_USE = PermissionProfile.new(
      key: "ask_on_first_use@v1", label: "Ask on first use",
      description: "Allow safe isolated work and ask before other eligible capabilities."
    ) do |descriptor, _role|
      PermissionProfile.safe_local?(descriptor) ? :allow : :ask
    end

    RESTRICTED = PermissionProfile.new(
      key: "restricted@v1", label: "Restricted",
      description: "Allow safe isolated work and deny other capabilities."
    ) do |descriptor, _role|
      PermissionProfile.safe_local?(descriptor) ? :allow : :deny
    end

    DEFINITIONS = [ FULL_ACCESS, ASK_ON_FIRST_USE, RESTRICTED ].index_by(&:key).freeze

    class << self
      def all = DEFINITIONS.values
      def fetch(key) = DEFINITIONS.fetch(key.to_s)
    end
  end
end
