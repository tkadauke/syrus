module RuntimeImages
  # Instance-owned, non-secret policy for the runtime-image build and launch
  # plane. Deployment credentials and executable paths remain environment
  # configuration; this policy is safe to expose and edit in administration.
  class EnvironmentPolicy
    DEFAULTS = {
      "builder" => {
        "max_concurrent_builds" => 2, "max_concurrent_per_namespace" => 1, "max_attempts" => 3,
        "cpus" => 2.0, "memory_bytes" => 4.gigabytes, "pids" => 512,
        "storage_bytes" => 10.gigabytes, "timeout_seconds" => 1500,
        "log_bytes" => 5.megabytes, "max_output_bytes" => 2.gigabytes
      },
      "supply_chain" => {
        "blocked_severities" => %w[critical high], "prohibited_packages" => []
      },
      "base_promotion" => {
        "minimum_abi" => RuntimeAbi.compatibility.fetch("min"),
        "maximum_abi" => RuntimeAbi.compatibility.fetch("max")
      },
      "recovery" => { "launch_failure_threshold" => 3, "rollback_retention_count" => 2 },
      "revocation" => { "terminate_running_turns_on_severe" => true },
      "worker_cache" => {
        "max_bytes" => 20.gigabytes, "max_concurrent_pulls" => 2,
        "unused_retention_hours" => 168
      },
      "scratch" => { "enabled" => false, "size_bytes" => 1.gigabyte }
    }.freeze

    ARRAY_KEYS = [%w[supply_chain blocked_severities], %w[supply_chain prohibited_packages]].freeze
    POSITIVE_KEYS = [
      %w[builder max_concurrent_builds], %w[builder max_concurrent_per_namespace], %w[builder max_attempts],
      %w[builder cpus], %w[builder memory_bytes], %w[builder pids], %w[builder storage_bytes],
      %w[builder timeout_seconds], %w[builder log_bytes], %w[builder max_output_bytes],
      %w[base_promotion minimum_abi], %w[base_promotion maximum_abi],
      %w[recovery launch_failure_threshold], %w[worker_cache max_concurrent_pulls],
      %w[worker_cache unused_retention_hours], %w[scratch size_bytes]
    ].freeze
    NON_NEGATIVE_KEYS = [
      %w[recovery rollback_retention_count], %w[worker_cache max_bytes]
    ].freeze

    class << self
      def current
        stored = AppSetting.current.runtime_environment_policy if AppSetting.current.has_attribute?(:runtime_environment_policy)
        DEFAULTS.deep_merge(stored.to_h.deep_stringify_keys)
      end

      def update!(attributes)
        policy = current.deep_merge(coerce(attributes.to_h.deep_stringify_keys))
        validate!(policy)
        AppSetting.current.update!(runtime_environment_policy: policy)
        policy
      end

      def value(*path) = current.dig(*path.map(&:to_s))

      def validate!(policy)
        unknown_sections = policy.keys - DEFAULTS.keys
        raise ArgumentError, "unknown policy sections: #{unknown_sections.join(', ')}" if unknown_sections.any?

        policy.each do |section, values|
          raise ArgumentError, "#{section} must be an object" unless values.is_a?(Hash)
          unknown = values.keys - DEFAULTS.fetch(section).keys
          raise ArgumentError, "unknown #{section} settings: #{unknown.join(', ')}" if unknown.any?
        end
        POSITIVE_KEYS.each { |path| numeric!(policy, path, positive: true) }
        NON_NEGATIVE_KEYS.each { |path| numeric!(policy, path, positive: false) }
        ARRAY_KEYS.each do |path|
          value = policy.dig(*path)
          raise ArgumentError, "#{path.join('.')} must be a list of strings" unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
        end
        severities = policy.dig("supply_chain", "blocked_severities")
        unknown = severities - %w[critical high medium low unknown]
        raise ArgumentError, "unknown vulnerability severities: #{unknown.join(', ')}" if unknown.any?
        min = policy.dig("base_promotion", "minimum_abi").to_i
        max = policy.dig("base_promotion", "maximum_abi").to_i
        raise ArgumentError, "minimum ABI must not exceed maximum ABI" if min > max
        policy
      end

      private

      def coerce(attributes)
        attributes.to_h.each_with_object({}) do |(section, values), result|
          defaults = DEFAULTS[section]
          result[section] = values.to_h.each_with_object({}) do |(key, value), section_result|
            default = defaults&.fetch(key, nil)
            section_result[key] = case default
            when Integer then Integer(value, exception: false) || value
            when Float then Float(value, exception: false) || value
            when TrueClass, FalseClass then ActiveModel::Type::Boolean.new.cast(value)
            else value
            end
          end
        end
      end

      def numeric!(policy, path, positive:)
        value = policy.dig(*path)
        valid = value.is_a?(Numeric) && (positive ? value.positive? : value >= 0)
        raise ArgumentError, "#{path.join('.')} must be #{positive ? 'positive' : 'non-negative'}" unless valid
      end
    end
  end
end
