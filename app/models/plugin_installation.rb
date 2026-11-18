class PluginInstallation < ApplicationRecord
  belongs_to :plugin_release

  attribute :roles, :json, default: -> { [] }

  validates :plugin_name, presence: true, uniqueness: true
  validates :desired_since, presence: true
  validate :plugin_name_matches_release
  validate :roles_are_names
  validate :release_artifact_is_available

  before_validation :set_desired_since, on: :create
  after_commit :publish_desired_state

  private

  def set_desired_since
    self.desired_since ||= Time.current
  end

  def plugin_name_matches_release
    return unless plugin_release && plugin_name.present?
    errors.add(:plugin_name, "must match the release name") unless plugin_name == plugin_release.name
  end

  def roles_are_names
    errors.add(:roles, "must be an array of non-empty names") unless roles.is_a?(Array) && roles.all? { |role| role.is_a?(String) && role.present? }
  end

  def release_artifact_is_available
    return unless enabled_for_sync && plugin_release && plugin_release.source != "bundled"
    errors.add(:plugin_release, "must have a verified artifact") unless plugin_release.archive.attached?
  end

  def publish_desired_state
    PluginDesiredState::Publisher.publish!
  end
end
