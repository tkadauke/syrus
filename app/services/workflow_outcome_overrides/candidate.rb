module WorkflowOutcomeOverrides
  Candidate = Data.define(:workflow, :step, :gate_failure, :label, :consequence) do
    def fingerprint
      Fingerprint.new(**Fingerprint::ATTRIBUTES.index_with { |key| attributes[key] })
    end

    def attributes
      gate_failure.slice(*Fingerprint::ATTRIBUTES).merge(
        job_id: workflow.job_id, workflow_id: workflow.id, step_id: step.id
      )
    end

    def as_json(*)
      attributes.merge(
        fingerprint_digest: fingerprint.digest,
        label:, consequence:,
        technically_overridable: gate_failure[:technically_overridable] == true
      )
    end
  end
end
