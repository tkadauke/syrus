# Durable "build this immutable source with this recipe" request in the
# runtime image build plane. The source capture, recipe, platform, and
# requester never change after creation; only state, attempt bookkeeping, and
# cancellation evolve, and only along TRANSITIONS.
#
# The deduplication tuple is (namespace, source_digest, recipe_digest,
# platform). While a request is live its tuple is mirrored into
# active_dedup_key, which carries a unique index, so concurrent submitters
# cannot create two live builds of the same thing.
class RuntimeImageBuildRequest < ApplicationRecord
  STATES = %w[queued building verifying succeeded failed canceled rejected].freeze
  TERMINAL_STATES = %w[succeeded failed canceled rejected].freeze
  IN_FLIGHT_STATES = %w[building verifying].freeze
  TRANSITIONS = {
    "queued" => %w[building canceled rejected],
    "building" => %w[verifying queued failed canceled],
    "verifying" => %w[succeeded queued failed canceled],
    "succeeded" => [],
    "failed" => [],
    "canceled" => [],
    "rejected" => []
  }.freeze

  class InvalidTransition < StandardError; end

  belongs_to :runtime_image_namespace
  has_many :attempts, -> { order(:number) }, class_name: "RuntimeImageBuildAttempt",
           foreign_key: :runtime_image_build_request_id, inverse_of: :request, dependent: :destroy
  has_one :result, class_name: "RuntimeImageBuildResult",
          foreign_key: :runtime_image_build_request_id, inverse_of: :request, dependent: :destroy
  has_one_attached :source_archive

  attr_readonly :runtime_image_namespace_id, :platform, :dedup_key, :source_kind, :source_ref, :source_digest,
                :source_manifest, :recipe_digest, :recipe, :requester_kind, :requester_ref

  attribute :source_manifest, :json, default: -> { {} }
  attribute :recipe, :json, default: -> { {} }

  validates :state, inclusion: { in: STATES }
  validates :platform, :dedup_key, :source_kind, :source_ref, :source_digest, :recipe_digest,
            :requester_kind, :requester_ref, presence: true
  validates :max_attempts, numericality: { only_integer: true, greater_than: 0 }

  before_validation { self.source_manifest ||= {} }
  before_validation { self.recipe ||= {} }
  before_save { self.active_dedup_key = terminal? ? nil : dedup_key }

  scope :queued, -> { where(state: "queued") }
  scope :in_flight, -> { where(state: IN_FLIGHT_STATES) }
  scope :live, -> { where.not(state: TERMINAL_STATES) }
  scope :terminal, -> { where(state: TERMINAL_STATES) }
  scope :startable, ->(now = Time.current) { queued.where(cancel_requested_at: nil).where("next_attempt_at IS NULL OR next_attempt_at <= ?", now).order(:id) }

  def self.dedup_key_for(namespace_id:, source_digest:, recipe_digest:, platform:)
    Digest::SHA256.hexdigest([ namespace_id, source_digest, recipe_digest, platform ].join("\0"))
  end

  STATES.each do |name|
    define_method(:"#{name}?") { state == name }
  end

  def terminal? = TERMINAL_STATES.include?(state)
  def in_flight? = IN_FLIGHT_STATES.include?(state)
  def cancel_requested? = cancel_requested_at.present?
  def attempts_exhausted? = attempts_count >= max_attempts
  def current_attempt = attempts.reorder(number: :desc).first

  # Moves to +to+ if the table allows it. Callers hold a row lock (see
  # RuntimeImages::Builds::Orchestrator), so the check is race-free.
  def transition_to!(to, **attrs)
    to = to.to_s
    unless TRANSITIONS.fetch(state, []).include?(to)
      raise InvalidTransition, "build request #{id} cannot move from #{state} to #{to}"
    end
    update!(attrs.merge(state: to))
  end
end
