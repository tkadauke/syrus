class ChatSession < ApplicationRecord
  belongs_to :repository
  belongs_to :user

  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :proposals, class_name: "ChatProposal", dependent: :destroy
  has_one :claude_session, as: :resumable, dependent: :destroy
  has_one :whiteboard, dependent: :destroy

  after_update_commit :broadcast_header, if: :cumulative_usage_previously_changed?

  validates :cumulative_input_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_output_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_cost_usd,
            numericality: { greater_than_or_equal_to: 0 }

  def turn_in_flight?
    latest_user_message = messages.where(role: "user").order(:created_at, :id).last
    return false unless latest_user_message

    messages
      .where("created_at > ? OR (created_at = ? AND id > ?)",
             latest_user_message.created_at,
             latest_user_message.created_at,
             latest_user_message.id)
      .where.not(role: "user")
      .none?
  end

  def cumulative_cost
    cumulative_cost_usd.to_d
  end

  def record_turn_usage!(result)
    updates = {}
    updates[:cumulative_input_tokens] = cumulative_input_tokens + result.input_tokens.to_i if result.input_tokens
    updates[:cumulative_output_tokens] = cumulative_output_tokens + result.output_tokens.to_i if result.output_tokens
    updates[:cumulative_cost_usd] = cumulative_cost + result.cost_usd.to_d if result.cost_usd
    update!(updates) if updates.any?
  end

  private

  def cumulative_usage_previously_changed?
    saved_change_to_cumulative_input_tokens? ||
      saved_change_to_cumulative_output_tokens? ||
      saved_change_to_cumulative_cost_usd?
  end

  def broadcast_header
    broadcast_replace_later_to(
      "chat_session_#{id}_header",
      target: "chat_session_#{id}_header",
      partial: "repositories/chats/header",
      locals: { repository: repository, chat_session: self }
    )
  end
end
