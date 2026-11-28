module RuntimeImages
  # Durable instance policy for runtime-image builds and worker execution.
  # Environment variables remain deployment fallbacks; values saved by an
  # administrator take precedence and are captured in build policy snapshots.
  class EnvironmentPolicy
    DEFAULTS = {
      "builder" => { "max_concurrent_builds" => 2, "max_concurrent_per_namespace" => 1,
                     "cpus" => 2.0, "memory_bytes" => 4.gigabytes, "storage_bytes" => 10.gigabytes,
                     "timeout_seconds" => 1500, "log_bytes" => 5.megabytes },
      "verification" => { "blocked_severities" => %w[critical high], "prohibited_packages" => [] },
      "base" => { "supported_abi_min" => RuntimeAbi.compatibility.fetch("min"),
                  "supported_abi_max" => RuntimeAbi.compatibility.fetch("max"),
                  "rollback_retention_days" => 90 },
      "revocation" => { "terminate_running_on_severe" => true },
      "cache" => { "max_concurrent_pulls" => 2, "pull_timeout_seconds" => 600,
                   "high_pressure_percent" => 80, "critical_pressure_percent" => 92 },
      "runtime" => { "mount_profile" => "standard", "scratch_size" => "1g" }
    }.freeze

    class Invalid < RuntimeImages::Error; end

    def self.defaults
      contract = RuntimeAbi.compatibility
      DEFAULTS.deep_merge(
        "base" => { "supported_abi_min" => contract.fetch("min"),
                    "supported_abi_max" => contract.fetch("max") }
      )
    end

    def self.current
      setting = AppSetting.current
      value = setting.has_attribute?(:runtime_environment_policy) ? setting.runtime_environment_policy : nil
      overrides = value.to_h.deep_stringify_keys
      normalize_stale_abi_override!(overrides)
      new(defaults.deep_merge(overrides), overrides: overrides)
    end

    def self.normalize_stale_abi_override!(overrides)
      base = overrides["base"]
      return unless base.is_a?(Hash) && base.key?("supported_abi_min") && base.key?("supported_abi_max")

      minimum = Integer(base["supported_abi_min"], exception: false)
      maximum = Integer(base["supported_abi_max"], exception: false)
      return unless minimum && maximum && minimum <= maximum

      contract = RuntimeAbi.compatibility
      return if minimum >= contract.fetch("min") && maximum <= contract.fetch("max")

      base.delete("supported_abi_min")
      base.delete("supported_abi_max")
    end
    private_class_method :normalize_stale_abi_override!

    def initialize(value, overrides: value)
      @value = value
      @overrides = overrides
      validate!
    end

    def to_h = @value.deep_dup
    def fetch(*path) = path.reduce(@value) { |memo, key| memo.fetch(key.to_s) }
    def override(*path) = path.reduce(@overrides) { |memo, key| memo.is_a?(Hash) ? memo[key.to_s] : nil }

    private

    def validate!
      positive = [ %w[builder max_concurrent_builds], %w[builder max_concurrent_per_namespace],
                   %w[builder cpus], %w[builder memory_bytes], %w[builder storage_bytes],
                   %w[builder timeout_seconds], %w[builder log_bytes], %w[cache max_concurrent_pulls],
                   %w[cache pull_timeout_seconds], %w[base rollback_retention_days] ]
      positive.each { |path| raise Invalid, "#{path.join('.')} must be positive" unless fetch(*path).to_f.positive? }
      %w[high_pressure_percent critical_pressure_percent].each do |key|
        raise Invalid, "cache.#{key} must be between 1 and 100" unless fetch("cache", key).to_f.between?(1, 100)
      end
      raise Invalid, "cache critical pressure must exceed high pressure" unless fetch("cache", "critical_pressure_percent").to_f > fetch("cache", "high_pressure_percent").to_f
      abi_min = Integer(fetch("base", "supported_abi_min"), exception: false)
      abi_max = Integer(fetch("base", "supported_abi_max"), exception: false)
      contract = RuntimeAbi.compatibility
      unless abi_min && abi_max && abi_min <= abi_max && abi_min >= contract.fetch("min") && abi_max <= contract.fetch("max")
        raise Invalid, "base supported ABI window must be within #{contract.fetch("min")}..#{contract.fetch("max")}"
      end
      raise Invalid, "runtime.mount_profile is invalid" unless fetch("runtime", "mount_profile").in?(%w[standard executable_scratch])
    end
  end
end
