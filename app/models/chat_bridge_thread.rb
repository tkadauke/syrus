class ChatBridgeThread < ApplicationRecord
  STATES = %w[open closed].freeze
  DEFAULT_MAX_HOPS = 6

  belongs_to :origin_chat_session, class_name: "ChatSession"
  belongs_to :target_chat_session, class_name: "ChatSession"
  belongs_to :opened_by_user, class_name: "User"

  validates :state, presence: true, inclusion: { in: STATES }
  validates :hop_count, numericality: { greater_than_or_equal_to: 0 }
  validates :max_hops, numericality: { greater_than: 0 }
  validate :chat_sessions_belong_to_same_user

  scope :open, -> { where(state: "open") }
  scope :closed, -> { where(state: "closed") }

  def open?
    state == "open"
  end

  def closed?
    state == "closed"
  end

  def hops_remaining
    max_hops - hop_count
  end

  def at_max_hops?
    hop_count >= max_hops
  end

  def close!
    update!(state: "closed")
  end

  def register_hop!
    increment!(:hop_count)
    close! if at_max_hops?
  end

  private

  def chat_sessions_belong_to_same_user
    return if origin_chat_session.nil? || target_chat_session.nil?
    return if origin_chat_session.user_id == target_chat_session.user_id

    errors.add(:target_chat_session, "must belong to the same operator as the origin chat session")
  end
end
