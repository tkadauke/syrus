module Permissions
  class ResourceScopeSchema
    STATUSES = %i[ok not_found invalid failed].freeze
    COMPARISONS = %i[equal narrower broader disjoint].freeze

    Result = Data.define(:status, :value, :errors) do
      def initialize(status:, value: nil, errors: [])
        super(status: status.to_sym, value: value, errors: Array(errors).map(&:to_s).freeze)
      end

      def success? = status == :ok
      def fail_closed? = !success?
    end

    attr_reader :type, :options

    def initialize(type:, options: nil, lookup: nil, normalize: nil, validate: nil, label: nil, compare: nil)
      @type = type.to_sym
      @options = options
      @lookup_callback = lookup
      @normalize_callback = normalize || method(:identity)
      @validate_callback = validate || method(:valid)
      @label_callback = label || method(:default_label)
      @compare_callback = compare || method(:default_compare)
      validate_contract!
      freeze
    end

    # Providers perform visibility filtering inside this callback. Nil is the
    # only public answer for both an unknown identifier and an invisible one.
    def lookup(identifier, context:)
      return failure(:failed) unless @lookup_callback

      resource = @lookup_callback.call(identifier, context: context)
      resource.nil? ? failure(:not_found) : success(resource)
    rescue StandardError
      failure(:failed)
    end

    def normalize(scope, context:)
      normalized = canonicalize(@normalize_callback.call(scope, context: context))
      validation_errors = Array(@validate_callback.call(normalized, context: context)).compact
      return failure(:invalid, validation_errors) if validation_errors.any?

      success(normalized)
    rescue StandardError
      failure(:failed)
    end

    def validate(scope, context:)
      normalized = normalize(scope, context: context)
      Result.new(status: normalized.status, errors: normalized.errors)
    end

    def label(scope, context:)
      normalized = normalize(scope, context: context)
      return normalized if normalized.fail_closed?

      value = @label_callback.call(normalized.value, context: context)
      value.present? ? success(value.to_s) : failure(:failed)
    rescue StandardError
      failure(:failed)
    end

    def compare(left, right, context:)
      normalized_left = normalize(left, context: context)
      return normalized_left if normalized_left.fail_closed?
      normalized_right = normalize(right, context: context)
      return normalized_right if normalized_right.fail_closed?

      comparison = @compare_callback.call(normalized_left.value, normalized_right.value, context: context).to_sym
      COMPARISONS.include?(comparison) ? success(comparison) : failure(:failed)
    rescue StandardError
      failure(:failed)
    end

    def to_h = { type: type, options: options }

    private

    def validate_contract!
      callbacks = {
        normalize: @normalize_callback,
        validate: @validate_callback,
        label: @label_callback,
        compare: @compare_callback
      }
      callbacks[:lookup] = @lookup_callback if @lookup_callback
      invalid = callbacks.filter_map { |name, callback| name unless callback.respond_to?(:call) }
      raise ArgumentError, "resource scope callbacks must respond to call: #{invalid.join(', ')}" if invalid.any?
    end

    def canonicalize(value)
      case value
      when Hash
        entries = value.to_h.map { |key, item| [ key.to_s, item ] }.sort_by(&:first)
        raise ArgumentError, "normalized scope contains duplicate keys" if entries.map(&:first).uniq.length != entries.length

        entries.to_h do |key, item|
          [ key.to_s.freeze, canonicalize(item) ]
        end.freeze
      when Array
        value.map { |item| canonicalize(item) }.freeze
      when String
        value.dup.freeze
      when Symbol, Numeric, TrueClass, FalseClass, NilClass
        value
      else
        raise ArgumentError, "normalized scopes must contain only JSON-compatible values"
      end
    end

    def identity(scope, context:) = scope
    def valid(scope, context:) = []
    def default_label(scope, context:) = scope.to_json
    def default_compare(left, right, context:) = left == right ? :equal : :disjoint
    def success(value = nil) = Result.new(status: :ok, value: value)
    def failure(status, errors = []) = Result.new(status: status, errors: errors)
  end
end
