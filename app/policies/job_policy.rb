# Job visibility starts with repository access, mirroring Epic's pattern, then
# applies enabled per-origin restrictions through Job.visible_to. Global admins
# bypass origin restrictions entirely.
#
# Mutation actions (approve, retry, cancel, submit chat feedback) require
# #write?: the creator, a global admin, or a write-tier-or-higher
# RepositoryMembership on the Job's repository.
class JobPolicy < ApplicationPolicy
  def show?
    admin? || visible?
  end

  def write?
    return true if admin?
    return false unless visible?

    owner? || record.repository.member_at_least?(user, "write")
  end

  # Scope intentionally does NOT bypass for admins: `Current.user.jobs` never
  # did, and the index/find call sites this backs must not change visibility.
  # Admin bypass lives on the per-record predicates above.
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.visible_to(user)
    end
  end

  private

  def owner?
    record.user_id == user&.id
  end

  def visible?
    Job.visible_to(user).exists?(id: record.id)
  end
end
