module Syrus
  module Metrics
    # Label cardinality is the standard way to destroy a Prometheus install: a
    # series is created per distinct combination of label values, so a single
    # unbounded label turns one metric into millions of series.
    #
    # This is an allowlist rather than a denylist on purpose. A denylist has to
    # anticipate the next identifier someone reaches for; an allowlist makes
    # adding a dimension a deliberate, reviewable change.
    #
    # It also carries a second job. Because no identifier can ever be a label,
    # the metric store structurally cannot contain a repository name, an issue
    # title, a prompt or a diff -- which is what lets telemetry share aggregates
    # without a scrubbing pass to get wrong. That is why this list is
    # non-negotiable rather than merely good practice.
    module TagAllowlist
      # Every entry here must have a small, bounded set of values that does not
      # grow with the amount of work Syrus does.
      #
      # `hostname` and `version` are the two deliberate exceptions to "bounded
      # set of values" in the strict sense -- pod names and git SHAs do churn
      # across deploys over a long enough retention window. They are allowed
      # anyway because the worker/fleet gauges (syrus_worker_cpu_percent,
      # syrus_instance_versions, ...) are sampled centrally from one process
      # and cached, not scraped per-pod -- there is no Prometheus-assigned
      # `instance` label to fall back on, since only the web role currently
      # serves /metrics (see config/syrus_docs/metrics.md). The set of values
      # actually alive at any moment is small (the live worker fleet, "two
      # versions during a rollout"), which is what keeps this from becoming
      # the per-request unbounded case the rest of this list guards against.
      ALLOWED = %i[
        queue
        state
        trigger_kind
        step_kind
        job_class
        decision
        outcome
        reason
        blocked_reason
        role
        kind
        provider
        mode
        credential_mode
        feature
        tool
        plugin
        hostname
        version
        job
        skip_reason
        problem_code
        unit_type
      ].freeze

      # Named explicitly so the error message can say *why*, rather than just
      # "not allowed". These are the ones people actually reach for.
      FORBIDDEN_HINTS = {
        job_id: "identifies one Job",
        run_id: "identifies one Run",
        workflow_id: "identifies one Workflow",
        step_id: "identifies one Step",
        repository: "grows with the number of repositories",
        repository_id: "grows with the number of repositories",
        repo: "grows with the number of repositories",
        slug: "grows with the number of repositories",
        sha: "unbounded",
        branch: "unbounded",
        user: "grows with the number of users",
        user_id: "grows with the number of users",
        user_email: "personal data, and unbounded",
        path: "unbounded",
        url: "unbounded",
        message: "unbounded free text",
        error: "unbounded free text"
      }.freeze

      def self.validate!(name:, tags:)
        Array(tags).each do |tag|
          next if ALLOWED.include?(tag.to_sym)

          hint = FORBIDDEN_HINTS[tag.to_sym]
          detail = hint ? " -- #{hint}" : ""
          raise Error,
                "metric #{name}: label #{tag.inspect} is not on the cardinality allowlist#{detail}. " \
                "High-cardinality identifiers belong in an event table (see mcp_tool_usages, " \
                "performance_log_events), not in metrics. Adding a label to " \
                "Syrus::Metrics::TagAllowlist::ALLOWED is a deliberate change."
        end
        true
      end
    end
  end
end
