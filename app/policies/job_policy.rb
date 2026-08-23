# Job visibility follows repository access, mirroring Epic's pattern
# (`Epic.accessible_to`): any user with a RepositoryMembership (any role) on
# a Job's repository can see that Job, not just its creator. Global admins
# bypass this entirely.
#
# Mutation actions (approve, retry, cancel, submit chat feedback) are
# intentionally NOT widened here -- they stay creator-or-admin-only for now
# (`owner?`/`update?`). Wider write-capability tiers land in a later
# repo-role-tiers job.
class JobPolicy < ApplicationPolicy
  def show?
    admin? || owner? || accessible?
  end

  def update?
    admin? || owner?
  end

  # Scope intentionally does NOT bypass for admins: `Current.user.jobs` never
  # did, and the index/find call sites this backs must not change visibility.
  # Admin bypass lives on the per-record predicates above.
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.accessible_to(user)
    end
  end

  private

  def owner?
    record.user_id == user&.id
  end

  def accessible?
    Job.accessible_to(user).exists?(id: record.id)
  end
end
