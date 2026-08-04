class WorkflowStepResourceProfile < ApplicationRecord
  PROFILE_VERSION = 1
  INPUT_RETAIN_AFTER = 180.days
  RETAIN_AFTER = 180.days

  SOFT_PREDICTION_SAMPLE_COUNT = 10
  NORMAL_ADMISSION_SAMPLE_COUNT = 30
  TIGHT_CONFIDENCE_SAMPLE_COUNT = 100

  CONFIDENCE_LEVELS = %w[ defaults_only soft normal tight ].freeze
  CONSERVATIVE_DEFAULTS = {
    duration_seconds: 30.minutes.to_i,
    cpu_pressure: 100.0,
    io_pressure: 100.0,
    memory_used_percent: 100.0,
    timeout_rate: 1.0,
    failure_rate: 1.0
  }.freeze

  belongs_to :repository

  validates :agent_provider, :trigger_kind, :step_kind, :profile_version, presence: true
  validates :grader_name, length: { maximum: 128 }, allow_blank: true
  validates :job_kind, length: { maximum: 64 }, allow_blank: true
  validates :sample_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :timeout_rate, :failure_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :profile_version, numericality: { only_integer: true, greater_than: 0 }
  validates :repository_id, uniqueness: {
    scope: %i[ agent_provider trigger_kind step_kind grader_name job_kind ],
    message: "already has a profile for this step key"
  }

  scope :stale, -> { stale_as_of(Time.current) }
  scope :stale_as_of, ->(now) { where("last_observed_at < ?", now - RETAIN_AFTER) }

  def self.refresh_all!(now: Time.current)
    WorkflowStepResourceProfiles::Refresh.new(now: now).refresh_all!
  end

  def self.refresh_for_summaries!(summaries, now: Time.current)
    WorkflowStepResourceProfiles::Refresh.new(now: now).refresh_for_summaries!(summaries)
  end

  def confidence_level
    return "tight" if sample_count >= TIGHT_CONFIDENCE_SAMPLE_COUNT
    return "normal" if sample_count >= NORMAL_ADMISSION_SAMPLE_COUNT
    return "soft" if sample_count >= SOFT_PREDICTION_SAMPLE_COUNT

    "defaults_only"
  end

  def permits_soft_prediction?
    sample_count >= SOFT_PREDICTION_SAMPLE_COUNT
  end

  def permits_normal_admission?
    sample_count >= NORMAL_ADMISSION_SAMPLE_COUNT
  end

  def permits_tight_confidence?
    sample_count >= TIGHT_CONFIDENCE_SAMPLE_COUNT
  end

  def conservative_prediction
    {
      duration_seconds: prediction_value(:duration_seconds, p90_duration_seconds),
      cpu_pressure: prediction_value(:cpu_pressure, p90_cpu_pressure),
      io_pressure: prediction_value(:io_pressure, p90_io_pressure),
      memory_used_percent: prediction_value(:memory_used_percent, p90_memory_used_percent),
      timeout_rate: prediction_value(:timeout_rate, timeout_rate),
      failure_rate: prediction_value(:failure_rate, failure_rate),
      confidence_level: confidence_level
    }
  end

  private

  def prediction_value(key, observed)
    return CONSERVATIVE_DEFAULTS.fetch(key) unless permits_soft_prediction?

    observed || CONSERVATIVE_DEFAULTS.fetch(key)
  end
end
