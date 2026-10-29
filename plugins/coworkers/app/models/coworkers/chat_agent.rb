class Coworkers::ChatAgent < ApplicationRecord
  self.table_name = "chat_agents"

  belongs_to :chat_session
  belongs_to :coworker, class_name: "Coworkers::Coworker"
  belongs_to :added_by_user, class_name: "User"

  validate :coworker_belongs_to_chat_owner

  private

  def coworker_belongs_to_chat_owner
    return if coworker.nil? || chat_session.nil?
    return if coworker.owner_user_id == chat_session.user_id

    errors.add(:coworker, "must belong to the chat owner")
  end
end
