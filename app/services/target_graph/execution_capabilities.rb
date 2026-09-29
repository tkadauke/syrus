class TargetGraph
  class ExecutionCapabilities < Data.define(:os, :arch, :toolchains, :runtimes, :features)
    DIMENSIONS = %w[os arch toolchains runtimes features].freeze
    CONSTRAINED_DIMENSIONS = %w[os arch].freeze
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

    def merge(other)
      return self if other.nil?
      raise ArgumentError, "capabilities must be a TargetGraph::ExecutionCapabilities" unless other.is_a?(self.class)

      self.class.new(
        os: merge_dimension(other, "os"),
        arch: merge_dimension(other, "arch"),
        toolchains: merge_dimension(other, "toolchains"),
        runtimes: merge_dimension(other, "runtimes"),
        features: merge_dimension(other, "features")
      )
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

    def merge_dimension(other, dimension)
      existing = public_send(dimension)
      addition = other.public_send(dimension)
      return existing if addition.empty?
      return addition if existing.empty?
      return existing if addition == [ CONFLICTING_WILDCARD ]
      return addition if existing == [ CONFLICTING_WILDCARD ]

      if CONSTRAINED_DIMENSIONS.include?(dimension) && existing != addition
        raise ArgumentError, "#{dimension}: imported values #{existing.inspect} conflict with overlay values #{addition.inspect}"
      end

      (existing + addition).uniq
    end
  end
end
