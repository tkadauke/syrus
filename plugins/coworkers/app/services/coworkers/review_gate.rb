module Coworkers
  # Contributes the coworker review loop to host workflows. The host owns
  # ordering and loop mechanics; this provider owns enablement, round budget,
  # and the execution metadata.
  class ReviewGate
    include Syrus::Plugin::ReviewGate

    def self.review_gates
      [
        {
          key: "coworker", step_kind: "coworker_review", after: %w[security], before: %w[visual],
          enabled_resolver: ->(job:, syrus_yml:, **) { plan(job, syrus_yml).enabled? },
          loop_budget: ->(job:, syrus_yml:, **) { plan(job, syrus_yml).rounds },
          handler_provider: "Coworkers::ReviewStep", prompt_provider: "Coworkers::ReviewPrompt",
          tool_provider: %w[submit_coworker_review], verdict_artifact: "coworker_review_iterations",
          failure_policy: { "deterministic" => "fail", "transient" => "retry" }, panel_capable: true
        }
      ]
    end

    def self.job_detail_fields(job)
      plan = Coworkers::ReviewPlan.for_job(job)
      {
        coworker_review_configuration: {
          enabled: plan.enabled?, rounds: plan.rounds, required: plan.required,
          criteria: plan.criteria, source: plan.source, note: plan.note
        }
      }
    end

    def self.plan(job, syrus_yml)
      Workflows::Base.resolve_plan(Coworkers::ReviewPlan, job, syrus_yml)
    end
  end
end
