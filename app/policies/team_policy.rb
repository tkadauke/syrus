# A team is visible to its members (any role) and manageable by its
# owner-tier members. Global admins bypass both.
class TeamPolicy < ApplicationPolicy
  def show?
    admin? || member?
  end

  def create?
    true
  end

  # Gates rename, membership CRUD, and repository-grant visibility
  # mutations initiated from the team side.
  def write?
    admin? || owner?
  end
  alias_method :update?, :write?
  alias_method :destroy?, :write?

  # Scope intentionally does NOT bypass for global admins on membership --
  # it does return every Team for an admin, but that mirrors #show?
  # bypassing for admins too (unlike RepositoryPolicy::Scope, which is
  # deliberately narrower than its per-record predicate).
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.all if admin?
      return scope.none unless user

      scope.joins(:team_memberships).where(team_memberships: { user_id: user.id }).distinct
    end
  end

  private

  def member?
    return false unless user
    record.team_memberships.exists?(user_id: user.id)
  end

  def owner?
    record.owned_by?(user)
  end
end
