class PluginRelease < ApplicationRecord
  SOURCES = %w[bundled upload registry hand_placed].freeze

  belongs_to :uploaded_by_user, class_name: "User", optional: true
  has_many :plugin_installations, dependent: :restrict_with_error
  has_one_attached :archive

  validates :name, :version, :content_digest, :trust_label, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :size_bytes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :name, uniqueness: { scope: %i[version content_digest] }
  after_commit :publish_desired_state, on: :update

  def store_archive!(io)
    PluginDesiredState::ArtifactStore.new(self).store!(io)
  end

  private

  def publish_desired_state
    PluginDesiredStatePublishJob.perform_later if plugin_installations.exists?
  end
end
