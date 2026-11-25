module WorkflowOutcomeOverrides
  class GateRegistry
    class UnknownGateKind < KeyError; end
    class DuplicateGateKind < ArgumentError; end

    def initialize
      @kinds = {}
    end

    def register(kind)
      raise DuplicateGateKind, "gate kind #{kind.name.inspect} is already registered" if @kinds.key?(kind.name)

      @kinds[kind.name] = kind
      kind
    end

    def fetch(name)
      @kinds.fetch(name.to_s) { raise UnknownGateKind, "unregistered gate kind #{name.inspect}" }
    end

    def registered?(name) = @kinds.key?(name.to_s)
    def kinds = @kinds.values.freeze

    class << self
      def default
        @default ||= new.tap do |registry|
          %w[review reviewer_infrastructure implementation_grader landing_grader].each do |name|
            registry.register(GateKind.new(name) { |failure| failure[:gate_identity].present? })
          end
        end
      end
    end
  end
end
