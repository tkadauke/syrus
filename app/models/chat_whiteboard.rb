class ChatWhiteboard < ApplicationRecord
  belongs_to :chat_session

  before_validation :ensure_scene_json

  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scene_json_has_elements_array

  def elements
    scene_json.fetch("elements", [])
  end

  def broadcast_to_canvas
    Turbo::StreamsChannel.broadcast_replace_later_to(
      "chat_session_#{chat_session_id}_whiteboard",
      target: "chat_session_#{chat_session_id}_whiteboard",
      partial: "repositories/chats/whiteboard",
      locals: { whiteboard: self }
    )
  end

  private

  def ensure_scene_json
    self.scene_json = { "elements" => [] } if scene_json.blank?
  end

  def scene_json_has_elements_array
    elements = scene_json.is_a?(Hash) && scene_json["elements"]
    errors.add(:scene_json, "elements must be an array") unless elements.is_a?(Array)
  end
end
