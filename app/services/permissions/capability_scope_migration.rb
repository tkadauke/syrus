module Permissions
  class CapabilityScopeMigration
    attr_reader :from_operation, :to_operation

    def initialize(from_operation:, to_operation:, transform:)
      @from_operation = versioned_identifier(from_operation, :from_operation)
      @to_operation = versioned_identifier(to_operation, :to_operation)
      @transform = transform
      raise ArgumentError, "scope migration transform must respond to call" unless transform.respond_to?(:call)
      raise ArgumentError, "scope migration must change the operation identifier" if @from_operation == @to_operation

      freeze
    end

    def migrate(scope, context:)
      @transform.call(scope, context: context)
    end

    def to_h = { from_operation: from_operation, to_operation: to_operation }

    private

    def versioned_identifier(value, field)
      identifier = value.to_s
      unless identifier.match?(/\A[a-z][a-z0-9_.-]*(?:\/[a-z][a-z0-9_.-]*)?@v[1-9]\d*\z/)
        raise ArgumentError, "#{field} must be a versioned identifier"
      end

      identifier.freeze
    end
  end
end
