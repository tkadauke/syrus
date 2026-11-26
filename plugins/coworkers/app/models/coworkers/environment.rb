# The single execution-environment definition a coworker owns, living in its
# existing persistent workspace. It points at immutable source revisions and
# at the candidate and active Runtime Image Service images; image data itself
# stays in RuntimeImage. This is a passive domain record; behavior built on
# it must sit behind the coworker_custom_environments gate.
class Coworkers::Environment < ApplicationRecord
  self.table_name = "coworker_environments"

  STATES = %w[unconfigured draft building candidate active failed revoked incompatible deleted].freeze
  TRANSITIONS = {
    "unconfigured" => %w[draft],
    "draft" => %w[draft building],
    "building" => %w[candidate failed draft],
    "candidate" => %w[active draft building failed revoked],
    "active" => %w[draft building revoked incompatible deleted],
    "failed" => %w[draft building],
    "revoked" => %w[draft deleted],
    "incompatible" => %w[draft building revoked deleted],
    "deleted" => []
  }.freeze

  class InvalidTransition < StandardError; end

  belongs_to :coworker, class_name: "Coworkers::Coworker", inverse_of: :environment, optional: true
  has_many :revisions, -> { order(:number) }, class_name: "Coworkers::EnvironmentRevision",
           foreign_key: :coworker_environment_id, inverse_of: :environment, dependent: :destroy
  belongs_to :active_revision, class_name: "Coworkers::EnvironmentRevision", optional: true
  belongs_to :candidate_revision, class_name: "Coworkers::EnvironmentRevision", optional: true
  belongs_to :active_runtime_image, class_name: "RuntimeImage", optional: true
  belongs_to :candidate_runtime_image, class_name: "RuntimeImage", optional: true
  belongs_to :last_audit_event, class_name: "RuntimeImageAuditEvent", optional: true

  attr_readonly :coworker_id

  validates :coworker_id, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validate :revisions_belong_to_environment

  STATES.each { |name| define_method(:"#{name}?") { state == name } }

  def transition_to!(next_state, **attributes)
    next_state = next_state.to_s
    unless TRANSITIONS.fetch(state, []).include?(next_state)
      raise InvalidTransition, "cannot move coworker environment from #{state} to #{next_state}"
    end

    update!(attributes.merge(state: next_state))
  end

  # Callers should hold the environment row lock; the unique (environment,
  # number) index rejects a concurrent capture that raced past it.
  def next_revision_number
    (revisions.maximum(:number) || 0) + 1
  end

  private

  def revisions_belong_to_environment
    %i[active_revision candidate_revision].each do |name|
      revision = public_send(name)
      next unless revision

      # A new environment owns no revisions yet, so any pointer is foreign.
      errors.add(name, I18n.t("api.coworkers.environment_foreign_revision")) if new_record? || revision.coworker_environment_id != id
    end
  end
end
