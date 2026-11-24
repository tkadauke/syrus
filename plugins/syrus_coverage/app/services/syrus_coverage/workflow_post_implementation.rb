module SyrusCoverage
  # Contributes the analysis to `workflow:post_implementation`: once, after the
  # judge and grade loops, so it sees the final graded tree and never runs
  # inside the grade loop. A repository gets the step only when it configures a
  # `coverage:` block.
  class WorkflowPostImplementation
    def self.post_implementation
      [
        {
          step_kind: "coverage_analyze",
          order: 10,
          enabled_for: ->(job) { SyrusCoverage::PlanReader.for_job(job).present? }
        }
      ]
    end
  end
end
