class WorkflowStepResourceProfile < ApplicationRecord
  PROFILE_VERSION = 1
  INPUT_RETAIN_AFTER = 180.days
  RETAIN_AFTER = 180.days

  SOFT_PREDICTION_SAMPLE_COUNT = 10
  NORMAL_ADMISSION_SAMPLE_COUNT = 30
  TIGHT_CONFIDENCE_SAMPLE_COUNT = 100

  CONFIDENCE_LEVELS = %w[ defaults_only soft normal tight ].freeze
  ATTRIBUTION_QUALITIES = %w[ defaults_only host_correlated mixed process_attributed ].freeze
  CONSERVATIVE_DEFAULTS = {
    duration_seconds: 30.minutes.to_i,
    process_attributed_duration_seconds: 30.minutes.to_i,
    process_attributed_cpu_seconds: 0.0,
    process_attributed_cpu_percent: 100.0,
    process_attributed_memory_bytes: nil,
    process_attributed_io_bytes: nil,
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
  validates :sample_count, :attributed_sample_count, :process_attributed_sample_count, :host_pressure_sample_count,
            numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :attribution_quality, inclusion: { in: ATTRIBUTION_QUALITIES }
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
    confidence_for(prediction_sample_count)
  end

  def attribution_confidence_level
    confidence_for(attributed_sample_count)
  end

  def permits_soft_prediction?
    prediction_sample_count >= SOFT_PREDICTION_SAMPLE_COUNT
  end

  def permits_attributed_prediction?
    attributed_sample_count >= SOFT_PREDICTION_SAMPLE_COUNT
  end

  def permits_normal_admission?
    prediction_sample_count >= NORMAL_ADMISSION_SAMPLE_COUNT
  end

  def permits_tight_confidence?
    prediction_sample_count >= TIGHT_CONFIDENCE_SAMPLE_COUNT
  end

  def prefers_process_attribution?
    process_attributed_sample_count >= SOFT_PREDICTION_SAMPLE_COUNT
  end

  def prediction_basis
    return "process_attributed" if prefers_process_attribution?
    return "host_correlated" if host_prediction_sample_count >= SOFT_PREDICTION_SAMPLE_COUNT

    "conservative_defaults"
  end

  def conservative_prediction
    values =
      if permits_attributed_prediction?
        attributed_prediction_values
      elsif permits_soft_prediction?
        host_correlated_prediction_values
      else
        default_prediction_values
      end

    values.merge(
      process_attributed_duration_seconds: prediction_value(:process_attributed_duration_seconds, p90_process_attributed_duration_seconds),
      process_attributed_cpu_seconds: prediction_value(:process_attributed_cpu_seconds, p90_process_attributed_cpu_seconds),
      process_attributed_cpu_percent: prediction_value(:process_attributed_cpu_percent, p90_process_attributed_cpu_percent),
      process_attributed_memory_bytes: prediction_value(:process_attributed_memory_bytes, p90_process_attributed_memory_bytes),
      process_attributed_io_bytes: prediction_value(:process_attributed_io_bytes, p90_process_attributed_io_bytes),
      host_pressure_cpu: prediction_value(:cpu_pressure, p90_host_pressure_cpu || p90_cpu_pressure),
      host_pressure_io: prediction_value(:io_pressure, p90_host_pressure_io || p90_io_pressure),
      host_pressure_memory_used_percent: prediction_value(:memory_used_percent, p90_host_pressure_memory_used_percent || p90_memory_used_percent),
      timeout_rate: prediction_value(:timeout_rate, timeout_rate),
      failure_rate: prediction_value(:failure_rate, failure_rate),
      confidence_level: confidence_level,
      attribution_confidence_level: attribution_confidence_level,
      attribution_quality: attribution_quality,
      prediction_basis: prediction_basis,
      sample_count: sample_count,
      attributed_sample_count: attributed_sample_count
    )
  end

  private

  def confidence_for(count)
    return "tight" if count >= TIGHT_CONFIDENCE_SAMPLE_COUNT
    return "normal" if count >= NORMAL_ADMISSION_SAMPLE_COUNT
    return "soft" if count >= SOFT_PREDICTION_SAMPLE_COUNT

    "defaults_only"
  end

  def prediction_sample_count
    [ attributed_sample_count.to_i, process_attributed_sample_count.to_i, host_prediction_sample_count ].max
  end

  def host_prediction_sample_count
    host_pressure_sample_count.to_i.positive? ? host_pressure_sample_count.to_i : sample_count.to_i
  end

  def attributed_prediction_values
    {
      duration_seconds: observed_or_default(:duration_seconds, p90_attributed_duration_seconds),
      cpu_pressure: observed_or_default(:cpu_pressure, p90_attributed_cpu_pressure),
      io_pressure: observed_or_default(:io_pressure, p90_attributed_io_pressure),
      memory_used_percent: observed_or_default(:memory_used_percent, p90_attributed_memory_used_percent),
      prediction_source: "command_attributed",
      fallback_reason: nil
    }
  end

  def host_correlated_prediction_values
    {
      duration_seconds: observed_or_default(:duration_seconds, p90_duration_seconds),
      cpu_pressure: observed_or_default(:cpu_pressure, p90_host_pressure_cpu || p90_cpu_pressure),
      io_pressure: observed_or_default(:io_pressure, p90_host_pressure_io || p90_io_pressure),
      memory_used_percent: observed_or_default(:memory_used_percent, p90_host_pressure_memory_used_percent || p90_memory_used_percent),
      prediction_source: "host_correlated",
      fallback_reason: "command_attributed_profile_unavailable"
    }
  end

  def default_prediction_values
    {
      duration_seconds: CONSERVATIVE_DEFAULTS.fetch(:duration_seconds),
      cpu_pressure: CONSERVATIVE_DEFAULTS.fetch(:cpu_pressure),
      io_pressure: CONSERVATIVE_DEFAULTS.fetch(:io_pressure),
      memory_used_percent: CONSERVATIVE_DEFAULTS.fetch(:memory_used_percent),
      prediction_source: "defaults_only",
      fallback_reason: "insufficient_command_and_host_profile_samples"
    }
  end

  def prediction_value(key, observed)
    return CONSERVATIVE_DEFAULTS.fetch(key) unless permits_soft_prediction?

    observed_or_default(key, observed)
  end

  def observed_or_default(key, observed)
    observed || CONSERVATIVE_DEFAULTS.fetch(key)
  end
end
