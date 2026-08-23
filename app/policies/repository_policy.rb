# A repository is visible/manageable only by users holding an `admin`-tier
# RepositoryMembership on it (the FK owner always has one -- see
# Repository#seed_owner_membership) -- what `Current.user.repositories`
# (the `belongs_to :user` FK) used to express before repository role tiers
# existed. Global admins bypass this entirely.
class RepositoryPolicy < ApplicationPolicy
  def show?
    admin?
  end

  def create?
    true
  end

  def update?
    admin?
  end

  def destroy?
    admin?
  end

  # write-tier-or-higher RepositoryMembership, or global admin. No
  # controller currently calls this (Repository mutation actions are all
  # settings/credentials-equivalent and gated by #admin? below) -- defined
  # for parity with JobPolicy#write? and for a future job that splits
  # narrower repository actions out from the admin-only gate.
  def write?
    admin? || member_at_least?("write")
  end

  # Repository-tier admin (an "admin" RepositoryMembership row) OR global
  # admin. Gates Repository settings/credentials actions that used to be
  # owner-FK-only.
  def admin?
    super || member_at_least?("admin")
  end

  # Scope intentionally does NOT bypass for global admins: `Current.user.repositories`
  # never did, and the index/find call sites this backs must not change
  # visibility. Admin bypass lives on the per-record predicates above.
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(id: RepositoryMembership.at_least("admin").where(user: user).select(:repository_id))
    end
  end

  private

  def member_at_least?(tier)
    return false unless user
    record.member_at_least?(user, tier)
  end
end
