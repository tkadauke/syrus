class Coworkers::TurnEnvironmentBinding < ApplicationRecord
  self.table_name = "coworker_turn_environment_bindings"

  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  SELECTION_KINDS = %w[standard custom].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :coworker, class_name: "Coworkers::Coworker"
  belongs_to :environment_activation, class_name: "Coworkers::EnvironmentActivation", optional: true
  belongs_to :environment_revision, class_name: "Coworkers::EnvironmentRevision", optional: true
  belongs_to :base_release, class_name: "CoworkerBaseRelease", foreign_key: :coworker_base_release_id
  belongs_to :runtime_image

  attr_readonly :chat_session_id, :user_message_id, :coworker_id, :environment_activation_id,
                :environment_revision_id, :coworker_base_release_id, :runtime_image_id,
                :feature_gate_enabled, :selection_kind, :image_digest, :base_digest,
                :runtime_abi, :revocation_state

  validates :user_message_id, uniqueness: true
  validates :selection_kind, inclusion: { in: SELECTION_KINDS }
  validates :image_digest, :base_digest, format: { with: DIGEST_FORMAT }
  validates :runtime_abi, numericality: { only_integer: true }
  validates :revocation_state, presence: true
  validate :selection_shape
  validate :immutable_references_match

  private

  def selection_shape
    custom = selection_kind == "custom"
    errors.add(:environment_activation, :invalid) unless environment_activation.present? == custom
    errors.add(:environment_revision, :invalid) unless environment_revision.present? == custom
  end

  def immutable_references_match
    return unless runtime_image && base_release

    errors.add(:image_digest, :invalid) unless image_digest == runtime_image.digest
    errors.add(:base_digest, :invalid) unless base_digest == base_release.digest
    errors.add(:runtime_abi, :invalid) unless runtime_abi == base_release.runtime_abi
    return unless environment_activation && environment_revision

    errors.add(:environment_activation, :invalid) unless environment_activation.revision == environment_revision
    errors.add(:runtime_image, :invalid) unless environment_activation.runtime_image_id == runtime_image_id
  end
end
