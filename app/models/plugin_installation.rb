class PluginInstallation < ApplicationRecord
  belongs_to :plugin_release

  validates :plugin_name, :desired_since, presence: true
  validates :plugin_name, uniqueness: true
  validate :plugin_name_matches_release
  validate :roles_are_strings

  before_validation :seed_roles
  before_validation :set_desired_since, on: :create
  after_commit :publish_desired_state

  private

  def seed_roles
    self.roles ||= []
  end

  def set_desired_since
    self.desired_since ||= Time.current
  end

  def plugin_name_matches_release
    return if plugin_release.blank? || plugin_name == plugin_release.name

    errors.add(:plugin_name, "must match the release name")
  end

  def roles_are_strings
    return if roles.is_a?(Array) && roles.all? { |role| role.is_a?(String) && role.present? }

    errors.add(:roles, "must be a list of non-empty strings")
  end

  def publish_desired_state
    PluginDesiredState::Publisher.publish!
  end
end
