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
        feature
        tool
        plugin
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
        hostname: "pod names churn on every deploy; use the scrape target's instance label",
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
