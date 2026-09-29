class TargetGraph
  class ExecutionCapabilities < Data.define(:os, :arch, :toolchains, :runtimes, :features)
    DIMENSIONS = %w[os arch toolchains runtimes features].freeze
    TOKEN_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z/
    CONFLICTING_WILDCARD = "any".freeze

    def initialize(os: [], arch: [], toolchains: [], runtimes: [], features: [])
      super(
        os: normalize_dimension(os, "os"),
        arch: normalize_dimension(arch, "arch"),
        toolchains: normalize_dimension(toolchains, "toolchains"),
        runtimes: normalize_dimension(runtimes, "runtimes"),
        features: normalize_dimension(features, "features")
      )
    end

    def empty?
      DIMENSIONS.all? { |dimension| public_send(dimension).empty? }
    end

    def to_h
      DIMENSIONS.each_with_object({}) do |dimension, hash|
        values = public_send(dimension)
        hash[dimension] = values if values.any?
      end
    end

    private

    def normalize_dimension(raw, dimension)
      values = Array(raw).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
      invalid = values.reject { |value| value.match?(TOKEN_PATTERN) }
      raise ArgumentError, "#{dimension}: values must match #{TOKEN_PATTERN.inspect}; invalid #{invalid.join(', ')}" if invalid.any?
      if values.include?(CONFLICTING_WILDCARD) && values.size > 1
        raise ArgumentError, "#{dimension}: #{CONFLICTING_WILDCARD.inspect} cannot be combined with specific values"
      end

      values
    end
  end
end
