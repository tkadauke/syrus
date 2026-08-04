class RunResourceSummary < ApplicationRecord
  RETAIN_AFTER = 30.days
  SUMMARY_VERSION = 2
  HOST_SAMPLE_CONFIDENCES = %w[ unknown low insufficient sufficient ].freeze
  PROCESS_ATTRIBUTION_CONFIDENCES = %w[ unknown low medium high ].freeze
  PRESSURE_LEVELS = WorkerHealthSampleAnalysis::LEVEL_ORDER.keys.freeze

  belongs_to :run
  belongs_to :job
  belongs_to :workflow, optional: true
  belongs_to :step, optional: true
  belongs_to :repository, optional: true
  belongs_to :user

  before_validation :default_json_fields

  validates :run_id, uniqueness: true
  validates :agent_provider, :trigger_kind, :host_sample_confidence, :host_pressure_level,
            :process_attribution_method, :process_attribution_version,
            :process_attribution_confidence, :summary_version, presence: true
  validates :host_sample_confidence, inclusion: { in: HOST_SAMPLE_CONFIDENCES }
  validates :host_pressure_level, inclusion: { in: PRESSURE_LEVELS }
  validates :process_attribution_confidence, inclusion: { in: PROCESS_ATTRIBUTION_CONFIDENCES }

  scope :prunable, -> { where("created_at < ?", RETAIN_AFTER.ago) }

  def self.refresh_for!(run, now: Time.current)
    RunResourceSummaries::Builder.new(run: run, now: now).refresh!
  end

  def self.refresh_for(run, now: Time.current)
    refresh_for!(run, now: now)
  rescue StandardError => e
    Rails.logger.warn("[RunResourceSummary] failed to refresh Run ##{run.id}: #{e.class}: #{e.message}")
    nil
  end

  private

  def default_json_fields
    self.host_pressure_reasons ||= []
    self.process_exit_statuses ||= []
  end
end
