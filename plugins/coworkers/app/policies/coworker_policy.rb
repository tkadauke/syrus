class CoworkerPolicy < ApplicationPolicy
  def create? = owner?
  def show? = owner?
  def update? = owner?
  def destroy? = owner?
  def manage_grants? = owner?
  def manage_chats? = owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(owner_user_id: user&.id)
    end
  end

  private

  def owner? = record.owner_user_id == user&.id
end
