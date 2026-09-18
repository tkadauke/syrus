module EmergencyLand
  # Repository-scoped permission gate for the emergency-land escape hatch.
  # Reuses RepositoryPolicy#admin? -- an admin-tier RepositoryMembership
  # (which includes the FK repository owner, auto-seeded with one -- see
  # Repository#seed_owner_membership) or a global admin -- rather than
  # inventing a new role for this one action.
  module Permission
    def self.granted?(user:, repository:)
      RepositoryPolicy.new(user, repository).admin?
    end
  end
end
