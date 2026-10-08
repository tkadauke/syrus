class TargetGraph
  class ExecutionCapabilities < Data.define(:os, :arch, :toolchain, :runtime)
    DIMENSIONS = %w[os arch toolchain runtime].freeze
    ALLOWED_OS_VALUES = %w[linux macos].freeze
    TOKEN_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z/
    CONFLICTING_WILDCARD = "any".freeze

    def initialize(os: [], arch: [], toolchain: [], runtime: [])
      super(
        os: normalize_os(os),
        arch: normalize_dimension(arch, "arch"),
        toolchain: normalize_dimension(toolchain, "toolchain"),
        runtime: normalize_dimension(runtime, "runtime")
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
        toolchain: merge_dimension(other, "toolchain"),
        runtime: merge_dimension(other, "runtime")
      )
    end

    private

    def normalize_os(raw)
      values = normalize_dimension(raw, "os")
      unsupported = values - ALLOWED_OS_VALUES
      if unsupported.any?
        raise ArgumentError, "os: values must be one of #{ALLOWED_OS_VALUES.join(', ')}; invalid #{unsupported.join(', ')}"
      end
      if values.size > 1
        raise ArgumentError, "os: choose exactly one of #{ALLOWED_OS_VALUES.join(', ')}"
      end

      values
    end

    def normalize_dimension(raw, dimension)
      values = Array(raw).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
      invalid = values.reject { |value| value.match?(TOKEN_PATTERN) }
      raise ArgumentError, "#{dimension}: values must match #{TOKEN_PATTERN.inspect}; invalid #{invalid.join(', ')}" if invalid.any?

      values
    end

    def merge_dimension(other, dimension)
      existing = public_send(dimension)
      addition = other.public_send(dimension)
      return existing if addition.empty?
      return addition if existing.empty?
      return existing if addition == [ CONFLICTING_WILDCARD ]
      return addition if existing == [ CONFLICTING_WILDCARD ]

      if existing != addition
        raise ArgumentError, "#{dimension}: imported values #{existing.inspect} conflict with overlay values #{addition.inspect}"
      end

      existing
    end
  end
end
