class PluginRelease < ApplicationRecord
  SOURCES = %w[bundled upload registry hand_placed].freeze
  TRUST_LABELS = %w[official verified community unsigned_local].freeze
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
  ARTIFACT_IDENTITY_ATTRIBUTES = %w[name version content_digest source size_bytes publisher_key_fingerprint signature plugin_registry_id].freeze

  belongs_to :uploaded_by, class_name: "User", optional: true
  belongs_to :plugin_registry, optional: true
  has_many :plugin_installations, dependent: :restrict_with_error
  has_one_attached :archive

  validates :name, :version, :trust_label, presence: true
  validates :trust_label, inclusion: { in: TRUST_LABELS }
  validates :publisher_key_fingerprint, format: { with: DIGEST_PATTERN }, allow_nil: true
  validates :source, inclusion: { in: SOURCES }
  validates :content_digest, format: { with: DIGEST_PATTERN }, uniqueness: { scope: %i[name version] }
  validates :size_bytes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :bundled_release_has_no_archive
  validate :artifact_identity_is_immutable, on: :update
  after_commit :publish_if_desired

  private

  def bundled_release_has_no_archive
    errors.add(:archive, I18n.t("server.errors.plugin_release.bundled_archive_present")) if source == "bundled" && archive.attached?
  end

  def artifact_identity_is_immutable
    changed = changes_to_save.keys & ARTIFACT_IDENTITY_ATTRIBUTES
    return if changed.empty?
    return unless archive.attached? || plugin_installations.exists?

    errors.add(:base, I18n.t("server.errors.plugin_release.artifact_identity_immutable"))
  end
  def publish_if_desired
    PluginDesiredState::Publisher.publish! if plugin_installations.exists?
  end
end
