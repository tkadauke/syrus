# One immutable captured source of a coworker environment. The source
# identity, recipe, and compatibility window never change after creation;
# only the lifecycle state and the references to the build and resulting
# image evolve as the revision is built, promoted, and retired.
class Coworkers::EnvironmentRevision < ApplicationRecord
  self.table_name = "coworker_environment_revisions"

  DIGEST_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  STATES = %w[draft building build_failed verifying candidate rejected active retired revoked].freeze
  TRANSITIONS = {
    "draft" => %w[building],
    "building" => %w[verifying build_failed],
    "build_failed" => [],
    "verifying" => %w[candidate rejected],
    "candidate" => %w[active retired rejected revoked],
    "rejected" => [],
    "active" => %w[retired revoked],
    "retired" => %w[active revoked],
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

  attr_readonly :coworker_environment_id, :number, :source_digest, :source_manifest, :recipe_digest,
                :runtime_abi, :compat_min, :compat_max, :coworker_base_release_id

  attribute :source_manifest, :json, default: -> { {} }

  validates :number, numericality: { only_integer: true, greater_than: 0 },
                     uniqueness: { scope: :coworker_environment_id }
  validates :state, inclusion: { in: STATES }
  validates :source_digest, presence: true, format: { with: DIGEST_FORMAT }
  validates :recipe_digest, format: { with: DIGEST_FORMAT }, allow_blank: true
  validates :runtime_abi, :compat_min, :compat_max, numericality: { only_integer: true }, allow_nil: true
  validate :compat_window_ordered
  validate :compat_window_complete

  STATES.each { |name| define_method(:"#{name}?") { state == name } }

  def transition_to!(next_state, **attributes)
    next_state = next_state.to_s
    unless TRANSITIONS.fetch(state, []).include?(next_state)
      raise InvalidTransition, "cannot move environment revision from #{state} to #{next_state}"
    end

    update!(attributes.merge(state: next_state))
  end

  def compatible_with?(abi)
    # An absent window (both bounds nil) places no constraint; a half-set
    # window is rejected by validation, so it never reaches here persisted.
    return true if compat_min.nil? && compat_max.nil?
    return false if compat_min.nil? || compat_max.nil?

    (compat_min..compat_max).cover?(abi)
  end

  # The source snapshot starts as a draft. Build admission binds its immutable
  # base/ABI tuple exactly once before leaving draft; ordinary updates remain
  # protected by attr_readonly afterward.
  def bind_build_inputs!(base_release_id:, runtime_abi:, compat_min:, compat_max:, recipe_digest:)
    raise ActiveRecord::ReadonlyAttributeError, "build inputs are already bound" if coworker_base_release_id
    raise InvalidTransition, "build inputs can only be bound to a draft revision" unless draft?

    self.class.where(id: id).update_all(coworker_base_release_id: base_release_id, runtime_abi: runtime_abi,
                                        compat_min: compat_min, compat_max: compat_max, recipe_digest: recipe_digest,
                                        updated_at: Time.current)
    reload
  end

  private

  def compat_window_complete
    return if compat_min.nil? == compat_max.nil?

    errors.add(compat_min.nil? ? :compat_min : :compat_max, I18n.t("api.coworkers.environment_compat_bound_missing"))
  end

  def compat_window_ordered
    return if compat_min.nil? || compat_max.nil?

    errors.add(:compat_max, I18n.t("api.coworkers.environment_compat_window_inverted")) if compat_max < compat_min
  end
end
