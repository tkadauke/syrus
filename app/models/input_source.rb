class InputSource < ApplicationRecord
  belongs_to :repository
  belongs_to :user

  attribute :credentials, :json
  encrypts :credentials

  after_initialize :seed_config

  validates :type, presence: true
  validates :repository_id, uniqueness: { scope: :type, message: "already has an input source of this type" }

  # --- Subclass interface ---
  #
  # Every InputSource subclass must implement:
  #
  #   #poll!
  #     Polls the external source and creates or updates Jobs accordingly.
  #     Called by PollInputSourceJob.
  #
  #   #validate_credentials!
  #     Raises descriptively if the stored credentials are unusable.
  #
  #   #config_schema
  #     Returns an array of field definition hashes for the settings UI,
  #     e.g. [{ key: "trigger_label", type: "string", required: true }].
  #
  #   #dedup_key(item)
  #     Returns the external_ref string for a given external item so the
  #     polling path can check for existing Jobs before creating new ones.

  def active?
    polling_enabled? && repository.present?
  end

  private

  def seed_config
    self.config ||= {}
  end
end
