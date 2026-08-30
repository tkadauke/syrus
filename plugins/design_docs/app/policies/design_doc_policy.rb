class DesignDocPolicy < ApplicationPolicy
  def show?
    admin? || visible?
  end

  def canonical_write?
    admin? || owner?
  end

  def suggest?
    admin? || owner? || collaborator?
  end

  def review?
    admin? || owner?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.all if admin?

      scope.visible_to(user)
    end
  end

  private

  def visible?
    DesignDocs::DesignDoc.visible_to(user).exists?(id: record.id)
  end

  def owner?
    record.owner_user_id == user&.id
  end

  def collaborator?
    record.collaborators.exists?(user_id: user&.id)
  end
end
