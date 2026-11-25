class Coworkers::ChatAgent < Syrus::Host::Record
  self.table_name = "coworkers_chat_agents"
  AFTER_REPLY_POLICIES = %w[wake quiet].freeze

  belongs_to :chat_session
  belongs_to :coworker, class_name: "Coworkers::Coworker"
  belongs_to :added_by_user, class_name: "User"

  validate :coworker_belongs_to_chat_owner
  validates :after_reply, inclusion: { in: AFTER_REPLY_POLICIES }

  after_create_commit :grant_source_chat_access
  after_destroy_commit :revoke_source_chat_access

  private

  def grant_source_chat_access
    chat_session.chat_shares.find_or_create_by!(target: coworker) { |share| share.shared_by_user = added_by_user }
  end

  def revoke_source_chat_access
    chat_session.chat_shares.where(target: coworker).destroy_all
  end

  def coworker_belongs_to_chat_owner
    return if coworker.nil? || chat_session.nil?
    return if coworker.owner_user_id == chat_session.user_id

    errors.add(:coworker, "must belong to the chat owner")
  end
end
