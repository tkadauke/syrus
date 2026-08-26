require "mcp"

module Mcp::Tools
  # Manual ingestion entry point alongside `PollExternalOpenPrsJob`'s
  # automatic per-tick ingestion — for a PR whose automatic heuristic
  # classification (`PrProvenanceClassifier`) was wrong, or one an operator
  # wants graded immediately rather than waiting for the next poll tick.
  class IngestPullRequestTool < MCP::Tool
    tool_name "ingest_pull_request"

    description "Ingest an external pull request on this repository. Without classification, " \
                "uses the same automatic heuristic PollExternalOpenPrsJob does; pass an explicit " \
                "classification override when those heuristics were wrong. If the PR was already " \
                "ingested, always returns the existing Job instead of re-ingesting — Syrus's " \
                "ingestion classes are not idempotent against re-classifying an already-created Job."

    input_schema(
      properties: {
        pr_number: { type: "integer", description: "Pull request number on this repository." },
        classification: {
          type: "string",
          enum: PrProvenanceClassifier::KINDS,
          description: "Optional override classification, used only on first ingestion — when automatic heuristics would misclassify this PR."
        }
      },
      required: %w[pr_number]
    )

    class << self
      def call(pr_number:, server_context:, classification: nil)
        context = McpToolContext.from_server_context(server_context)
        repository = context.repository
        return Mcp::Tools.invalid("no repository attached") unless repository

        if classification.present? && !PrProvenanceClassifier::KINDS.include?(classification)
          return Mcp::Tools.invalid("classification must be one of: #{PrProvenanceClassifier::KINDS.join(', ')}")
        end

        existing = repository.jobs.find_by(external_pr_number: pr_number)
        if existing
          return Mcp::Tools.success(pr_number: pr_number, already_ingested: true, job: job_payload(existing))
        end

        client = GithubClient.for(repository: repository, user: context.user)
        pr = client.pull_request(repository.slug, pr_number)
        fork_pr = pr.head&.repo&.full_name != pr.base&.repo&.full_name
        resolved_classification = classification.presence || PrProvenanceClassifier.classify(repository: repository, pr: pr)

        job = nil
        Job.transaction do
          job = ExternalPrIngestions::Base.for(resolved_classification).ingest!(repository: repository, pr: pr, fork_pr: fork_pr)
        end

        Mcp::Tools.success(
          pr_number: pr_number,
          already_ingested: false,
          classification: resolved_classification,
          job: job_payload(job)
        )
      rescue Octokit::NotFound
        Mcp::Tools.invalid("pull request not found: ##{pr_number}")
      rescue Octokit::Error => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def job_payload(job)
        return nil unless job

        { id: job.id, slug: job.slug, state: job.state, kind: job.kind, epic_id: job.epic_id }
      end
    end
  end
end
