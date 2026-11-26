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
          registry.register(GateKind.new("review", resumer: Resumers::Review) { |failure| failure[:gate_identity].present? })
          registry.register(GateKind.new("reviewer_infrastructure", resumer: Resumers::Review) { |failure| failure[:gate_identity].present? })
          registry.register(GateKind.new("implementation_grader", resumer: Resumers::Grader) { |failure| failure[:gate_identity].present? })
          registry.register(GateKind.new("landing_grader", resumer: Resumers::Grader) { |failure| failure[:gate_identity].present? })
        end
      end
    end
  end
end
