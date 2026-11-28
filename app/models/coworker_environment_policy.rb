class CoworkerEnvironmentPolicy
  DEFAULTS = {
    "builder" => { "max_concurrent_builds" => 2, "max_concurrent_per_namespace" => 1, "max_attempts" => 3,
                   "cpus" => 2.0, "memory_bytes" => 4.gigabytes, "storage_bytes" => 10.gigabytes,
                   "timeout_seconds" => 1500, "log_bytes" => 5.megabytes, "max_output_bytes" => 2.gigabytes },
    "verification" => { "blocked_severities" => %w[critical high], "prohibited_packages" => [] },
    "base" => { "supported_abi_min" => 1, "supported_abi_max" => 1, "automatic_rollback_threshold" => 3 },
    "revocation" => { "severe_running_turns" => "terminate" },
    "cache" => { "max_bytes" => 20.gigabytes, "max_concurrent_pulls" => 2, "prefetch_active" => false },
    "scratch" => { "profile" => "standard", "size" => "1g" }
  }.freeze

  SEVERITIES = %w[critical high medium low unknown].freeze
  REVOCATION_RESPONSES = %w[terminate allow_to_finish].freeze
  SCRATCH_PROFILES = %w[standard executable_scratch].freeze

  def self.current
    DEFAULTS.deep_merge(AppSetting.current.coworker_environment_policy.to_h.deep_stringify_keys)
  end

  def self.validate!(value)
    policy = DEFAULTS.deep_merge(Hash(value).deep_stringify_keys)
    integers = %w[max_concurrent_builds max_concurrent_per_namespace max_attempts memory_bytes storage_bytes timeout_seconds log_bytes max_output_bytes]
    integers.each do |key|
      value = Integer(policy.dig("builder", key), exception: false)
      raise ArgumentError, "builder.#{key} must be positive" unless value&.positive?
      policy["builder"][key] = value
    end
    cpus = Float(policy.dig("builder", "cpus"), exception: false)
    raise ArgumentError, "builder.cpus must be positive" unless cpus&.positive?
    policy["builder"]["cpus"] = cpus
    %w[supported_abi_min supported_abi_max automatic_rollback_threshold].each do |key|
      value = Integer(policy.dig("base", key), exception: false)
      raise ArgumentError, "base.#{key} must be a non-negative integer" unless value && value >= 0
      policy["base"][key] = value
    end
    %w[max_bytes max_concurrent_pulls].each do |key|
      value = Integer(policy.dig("cache", key), exception: false)
      raise ArgumentError, "cache.#{key} must be positive" unless value&.positive?
      policy["cache"][key] = value
    end
    policy["cache"]["prefetch_active"] = ActiveModel::Type::Boolean.new.cast(policy.dig("cache", "prefetch_active"))
    severities = Array(policy.dig("verification", "blocked_severities")).map(&:to_s)
    raise ArgumentError, "blocked severities are invalid" unless severities.present? && (severities - SEVERITIES).empty?
    raise ArgumentError, "revocation response is invalid" unless REVOCATION_RESPONSES.include?(policy.dig("revocation", "severe_running_turns"))
    raise ArgumentError, "scratch profile is invalid" unless SCRATCH_PROFILES.include?(policy.dig("scratch", "profile"))
    raise ArgumentError, "ABI window is invalid" if policy.dig("base", "supported_abi_min").to_i > policy.dig("base", "supported_abi_max").to_i
    policy
  end
end
