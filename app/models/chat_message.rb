class ChatMessage < ApplicationRecord
  ROLES = %w[ user assistant tool_use tool_result system ].freeze
  WHITEBOARD_ALWAYS_COLLAPSED_TOOLS = %w[ read_scene update_scene ].freeze
  WHITEBOARD_ALWAYS_EXPANDED_TOOLS = %w[ clear_canvas ].freeze
  WHITEBOARD_MUTATION_TOOLS = %w[ move_element delete_element ].freeze

  belongs_to :chat_session
  belongs_to :proposal, class_name: "ChatProposal", optional: true

  after_create_commit :broadcast_to_chat

  validates :role, presence: true, inclusion: { in: ROLES }
  validate :content_is_present

  def tool_use_default_open?
    return false unless role == "tool_use"
    return true if proposal_tool_use?
    return true if WHITEBOARD_ALWAYS_EXPANDED_TOOLS.include?(normalized_tool_name)
    return false if WHITEBOARD_ALWAYS_COLLAPSED_TOOLS.include?(normalized_tool_name)
    return first_tool_use_of_kind_in_turn? if whiteboard_activity_tool?

    false
  end

  broadcasts_to ->(message) { "chat_session_#{message.chat_session_id}_messages" },
                inserts_by: :append,
                target: ->(message) { "chat_session_#{message.chat_session_id}_messages" }

  private

  def normalized_tool_name
    content_name = content["name"] if content.is_a?(Hash)
    (tool_name.presence || content_name.presence || "").to_s
  end

  def proposal_tool_use?
    normalized_tool_name.include?("proposal") || normalized_tool_name.include?("propose_issue")
  end

  def whiteboard_activity_tool?
    normalized_tool_name.start_with?("draw_") || WHITEBOARD_MUTATION_TOOLS.include?(normalized_tool_name)
  end

  def first_tool_use_of_kind_in_turn?
    return true unless persisted?

    previous_user_id = chat_session.messages
      .where(role: "user")
      .where("id < ?", id)
      .order(id: :desc)
      .limit(1)
      .pick(:id)

    prior_same_tool = chat_session.messages
      .where(role: "tool_use", tool_name: normalized_tool_name)
      .where("id < ?", id)

    prior_same_tool = prior_same_tool.where("id > ?", previous_user_id) if previous_user_id
    !prior_same_tool.exists?
  end

  def content_is_present
    errors.add(:content, "can't be blank") if content.nil?
  end

  def broadcast_to_chat
    broadcast_append_later_to(
      "chat_session_#{chat_session_id}_messages",
      target: "chat_session_#{chat_session_id}_messages",
      partial: "repositories/chats/message",
      locals: { message: self, repository: chat_session.repository }
    )
  end
end
