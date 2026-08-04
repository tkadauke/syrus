class RunResourceSummary < ApplicationRecord
  RETAIN_AFTER = 30.days
  SUMMARY_VERSION = 1
  SAMPLE_CONFIDENCES = %w[ unknown low insufficient sufficient ].freeze
  PRESSURE_LEVELS = WorkerHealthSampleAnalysis::LEVEL_ORDER.keys.freeze

  belongs_to :run
  belongs_to :job
  belongs_to :workflow, optional: true
  belongs_to :step, optional: true
  belongs_to :repository, optional: true
  belongs_to :user

  before_validation :default_resource_pressure_reasons

  validates :run_id, uniqueness: true
  validates :agent_provider, :trigger_kind, :sample_confidence, :resource_pressure_level, :summary_version, presence: true
  validates :sample_confidence, inclusion: { in: SAMPLE_CONFIDENCES }
  validates :resource_pressure_level, inclusion: { in: PRESSURE_LEVELS }

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

  def default_resource_pressure_reasons
    self.resource_pressure_reasons ||= []
  end
end
