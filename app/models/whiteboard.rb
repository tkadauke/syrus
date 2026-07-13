class Whiteboard < ApplicationRecord
  MAX_ELEMENTS = 1000
  ELEMENT_LIMIT_MESSAGE = "Whiteboard at element limit (1000). Operator must clear or remove some shapes before adding more."
  EMPTY_SCENE = { "elements" => [], "appState" => {}, "files" => {} }.freeze
  TRANSIENT_APP_STATE_KEYS = %w[
    activeTool
    collaborators
    selectedElementIds
    selectedGroupIds
    editingElement
    resizingElement
    draggingElement
    multiElement
    suggestedBindings
    startBoundElement
  ].freeze

  belongs_to :chat_session

  # MySQL 8 doesn't allow defaults on JSON columns, so we seed an
  # empty scene on initialize. Existing rows keep whatever they had
  # serialized previously.
  after_initialize :seed_empty_scene_json, if: :new_record?

  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :scene_json_has_elements_array
  validate :scene_json_has_hash_app_state
  validate :scene_json_has_hash_files
  validate :scene_json_within_element_limit

  def self.default_state
    default_scene.merge("version" => 0)
  end

  def self.default_scene
    JSON.parse(JSON.generate(EMPTY_SCENE))
  end

  def self.normalize_scene!(scene_json)
    scene = JSON.parse(JSON.generate(scene_json || {}))
    raise ArgumentError, "scene_json must be a hash" unless scene.is_a?(Hash)
    raise ArgumentError, "scene_json must include an elements array" unless scene["elements"].is_a?(Array)

    app_state = scene.key?("appState") ? scene["appState"] : scene["app_state"]
    app_state ||= {}
    files = scene["files"] || {}
    raise ArgumentError, "scene_json appState must be a hash" unless app_state.is_a?(Hash)
    raise ArgumentError, "scene_json files must be a hash" unless files.is_a?(Hash)

    {
      "elements" => scene.fetch("elements"),
      "appState" => sanitize_app_state(app_state),
      "files" => files
    }
  end

  def self.sanitize_app_state(app_state)
    app_state.except(*TRANSIENT_APP_STATE_KEYS)
  end

  def current_state
    self.class.normalize_scene!(scene_json).merge("version" => version)
  end

  def elements
    current_scene.fetch("elements")
  end

  def app_state
    current_scene.fetch("appState")
  end

  def files
    current_scene.fetch("files")
  end

  def replace_elements!(elements)
    replace_scene!(current_scene.merge("elements" => elements))
  end

  def replace_scene!(scene)
    normalized = self.class.normalize_scene!(scene)
    raise ArgumentError, self.class.element_limit_message if normalized.fetch("elements").size > MAX_ELEMENTS

    update!(
      scene_json: normalized,
      version: version + 1,
      last_edited_at: Time.current
    )
    broadcast_scene
  end

  def broadcast_scene
    AppEvents.broadcast(
      user: chat_session.user,
      type: "updated",
      resource: "chat",
      id: chat_session_id,
      changed: [ "whiteboard" ],
      payload: current_state
    )
  end

  def self.element_limit_message
    ELEMENT_LIMIT_MESSAGE
  end

  private

  def seed_empty_scene_json
    self.scene_json = self.class.default_scene if scene_json.nil? || scene_json == { "elements" => [] }
  end

  def scene_json_has_elements_array
    unless scene_json.is_a?(Hash)
      errors.add(:scene_json, "must be a hash")
      return
    end

    errors.add(:scene_json, "must include an elements array") unless scene_json["elements"].is_a?(Array)
  end

  def scene_json_has_hash_app_state
    return unless scene_json.is_a?(Hash)

    app_state = scene_json.key?("appState") ? scene_json["appState"] : scene_json["app_state"]
    errors.add(:scene_json, "appState must be a hash") unless app_state.nil? || app_state.is_a?(Hash)
  end

  def scene_json_has_hash_files
    return unless scene_json.is_a?(Hash)

    errors.add(:scene_json, "files must be a hash") unless scene_json["files"].nil? || scene_json["files"].is_a?(Hash)
  end

  def scene_json_within_element_limit
    return unless scene_json.is_a?(Hash) && scene_json["elements"].is_a?(Array)

    errors.add(:scene_json, self.class.element_limit_message) if scene_json["elements"].size > MAX_ELEMENTS
  end

  def current_scene
    self.class.normalize_scene!(scene_json)
  end
end
