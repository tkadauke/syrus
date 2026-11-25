module WorkflowOutcomeOverrides
  class GateKind
    class InvalidRegistration < ArgumentError; end

    attr_reader :name

    def initialize(name, &failure_contract)
      @name = name.to_s
      @failure_contract = failure_contract
      raise InvalidRegistration, "gate kind is required" if @name.blank?
      raise InvalidRegistration, "failure contract is required" unless @failure_contract
    end

    def overridable_failure?(failure)
      failure = failure.to_h.symbolize_keys
      failure[:outcome].to_s == "failed" &&
        failure[:technically_overridable] == true &&
        failure[:structural] != true &&
        @failure_contract.call(failure) == true
    end
  end
end
