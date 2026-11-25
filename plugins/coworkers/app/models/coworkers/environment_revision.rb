# One immutable captured source of a coworker environment. The source
# identity, recipe, and compatibility window never change after creation;
# only the lifecycle state and the references to the build and resulting
# image evolve as the revision is built, promoted, and retired.
class Coworkers::EnvironmentRevision < ApplicationRecord
  self.table_name = "coworker_environment_revisions"

  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  STATES = %w[recorded building built candidate active superseded failed revoked].freeze
  TRANSITIONS = {
    "recorded" => %w[building failed],
    "building" => %w[built failed recorded],
    "built" => %w[candidate failed revoked],
    "candidate" => %w[active superseded failed revoked],
    "active" => %w[superseded revoked],
    "superseded" => %w[active revoked],
    "failed" => [],
    "revoked" => []
  }.freeze

  class InvalidTransition < StandardError; end

  belongs_to :environment, class_name: "Coworkers::Environment", foreign_key: :coworker_environment_id,
             inverse_of: :revisions
  belongs_to :build_request, class_name: "RuntimeImageBuildRequest",
             foreign_key: :runtime_image_build_request_id, optional: true
  belongs_to :runtime_image, optional: true
  belongs_to :base_release, class_name: "CoworkerBaseRelease", foreign_key: :coworker_base_release_id, optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :audit_event, class_name: "RuntimeImageAuditEvent", optional: true

  attr_readonly :coworker_environment_id, :number, :source_digest, :source_manifest, :recipe_digest

  attribute :source_manifest, :json, default: -> { {} }

  validates :number, numericality: { only_integer: true, greater_than: 0 },
                     uniqueness: { scope: :coworker_environment_id }
  validates :state, inclusion: { in: STATES }
  validates :source_digest, presence: true, format: { with: DIGEST_FORMAT }
  validates :recipe_digest, format: { with: DIGEST_FORMAT }, allow_blank: true
  validates :runtime_abi, :compat_min, :compat_max, numericality: { only_integer: true }, allow_nil: true
  validate :compat_window_ordered

  STATES.each { |name| define_method(:"#{name}?") { state == name } }

  def transition_to!(next_state, **attributes)
    next_state = next_state.to_s
    unless TRANSITIONS.fetch(state, []).include?(next_state)
      raise InvalidTransition, "cannot move environment revision from #{state} to #{next_state}"
    end

    update!(attributes.merge(state: next_state))
  end

  def compatible_with?(abi)
    return true if compat_min.nil? || compat_max.nil?

    (compat_min..compat_max).cover?(abi)
  end

  private

  def compat_window_ordered
    return if compat_min.nil? || compat_max.nil?

    errors.add(:compat_max, "must not be below compat_min") if compat_max < compat_min
  end
end
