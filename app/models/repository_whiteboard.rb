class RepositoryWhiteboard < ApplicationRecord
  belongs_to :repository

  before_validation :ensure_scene_json
  after_update_commit :broadcast_scene

  validates :repository_id, uniqueness: true
  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def elements
    Array(scene_json.is_a?(Hash) ? scene_json["elements"] : nil)
  end

  def apply_elements!(elements, expected_version:)
    with_lock do
      return false if version != expected_version

      update!(
        scene_json: { "elements" => Array(elements) },
        version: version + 1
      )
    end
    true
  end

  def broadcast_dom_id
    "repository_#{repository_id}_whiteboard_broadcast"
  end

  private

  def ensure_scene_json
    self.scene_json = { "elements" => [] } unless scene_json.is_a?(Hash)
    scene_json["elements"] = Array(scene_json["elements"])
  end

  def broadcast_scene
    broadcast_replace_later_to(
      repository,
      "whiteboard",
      target: broadcast_dom_id,
      partial: "repositories/whiteboards/broadcast",
      locals: { whiteboard: self }
    )
  end
end
