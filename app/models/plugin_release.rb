class PluginRelease < ApplicationRecord
  SOURCES = %w[bundled upload registry hand_placed].freeze
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

  belongs_to :uploaded_by, class_name: "User", optional: true
  has_many :plugin_installations, dependent: :restrict_with_error
  has_one_attached :archive

  validates :name, :version, :trust_label, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :content_digest, format: { with: DIGEST_PATTERN }, uniqueness: { scope: %i[name version] }
  validates :size_bytes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :bundled_release_has_no_archive
  after_commit :publish_if_desired

  private

  def bundled_release_has_no_archive
    errors.add(:archive, "must be absent for bundled releases") if source == "bundled" && archive.attached?
  end

  def publish_if_desired
    PluginDesiredState::Publisher.publish! if plugin_installations.exists?
  end
end
