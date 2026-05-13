class Whiteboard < ApplicationRecord
  belongs_to :chat_session

  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scene_json_has_elements_array

  def self.default_state
    { "elements" => [], "version" => 0 }
  end

  def current_state
    {
      "elements" => scene_json.fetch("elements"),
      "version" => version
    }
  end

  def elements
    scene_json.fetch("elements")
  end

  def replace_elements!(elements)
    update!(
      scene_json: { "elements" => elements },
      version: version + 1,
      last_edited_at: Time.current
    )
    broadcast_scene
  end

  def broadcast_scene
    Turbo::StreamsChannel.broadcast_stream_to(
      broadcast_channel,
      content: current_state.to_json
    )
  end

  def broadcast_channel
    "chat_session_#{chat_session_id}_whiteboard"
  end

  private

  def scene_json_has_elements_array
    unless scene_json.is_a?(Hash)
      errors.add(:scene_json, "must be a hash")
      return
    end

    errors.add(:scene_json, "must include an elements array") unless scene_json["elements"].is_a?(Array)
  end
end
