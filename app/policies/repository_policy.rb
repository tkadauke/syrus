# Wraps today's Repository access rule: a repository is visible/manageable
# only by the user that owns it (the `belongs_to :user` FK), i.e. what
# `Current.user.repositories` already expressed. Global admins bypass this
# entirely.
class RepositoryPolicy < ApplicationPolicy
  def show?
    admin? || owner?
  end

  def create?
    true
  end

  def update?
    show?
  end

  def destroy?
    show?
  end

  # Scope intentionally does NOT bypass for admins: `Current.user.repositories`
  # never did, and the index/find call sites this backs must not change
  # visibility. Admin bypass lives on the per-record predicates above,
  # ready for a later epic job to wire into `authorize` calls.
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user: user)
    end
  end

  private

  def owner?
    record.user_id == user&.id
  end
end
