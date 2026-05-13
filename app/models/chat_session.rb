require "bigdecimal"

class ChatSession < ApplicationRecord
  COST_PER_TOKEN = {
    claude_sonnet: {
      input: BigDecimal("0.000003"),
      output: BigDecimal("0.000015")
    },
    claude_opus: {
      input: BigDecimal("0.000015"),
      output: BigDecimal("0.000075")
    }
  }.freeze
  DEFAULT_COST_PROFILE = :claude_sonnet

  belongs_to :repository
  belongs_to :user

  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :proposals, class_name: "ChatProposal", dependent: :destroy
  has_one :claude_session, as: :resumable, dependent: :destroy

  after_update_commit :broadcast_header, if: :cumulative_tokens_previously_changed?

  validates :cumulative_input_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_output_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

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

  def cumulative_cost(cost_profile = DEFAULT_COST_PROFILE)
    rates = COST_PER_TOKEN.fetch(cost_profile.to_sym)
    (cumulative_input_tokens * rates.fetch(:input)) +
      (cumulative_output_tokens * rates.fetch(:output))
  end

  private

  def cumulative_tokens_previously_changed?
    saved_change_to_cumulative_input_tokens? || saved_change_to_cumulative_output_tokens?
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
