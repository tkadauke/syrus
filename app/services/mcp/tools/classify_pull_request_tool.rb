require "mcp"

module Mcp::Tools
  class ClassifyPullRequestTool < MCP::Tool
    tool_name "classify_pull_request"

    description "Classify an open pull request on this repository by Syrus provenance " \
                "(external_unknown, syrus_job_export, syrus_branch_export, syrus_promotion, " \
                "manual_hotfix — see PrProvenanceClassifier), with the evidence behind the call."

    input_schema(
      properties: {
        pr_number: { type: "integer", description: "Pull request number on this repository." }
      },
      required: %w[pr_number]
    )

    class << self
      def call(pr_number:, server_context:)
        context = McpToolContext.from_server_context(server_context)
        repository = context.repository
        return Mcp::Tools.invalid("no repository attached") unless repository

        client = GithubClient.for(repository: repository, user: context.user)
        pr = client.pull_request(repository.slug, pr_number)

        classification = PrProvenanceClassifier.classify(repository: repository, pr: pr)
        marker = PrProvenanceMarker.parse(pr.body)

        Mcp::Tools.success(
          repository: repository.slug,
          pr_number: pr_number,
          classification: classification,
          evidence: {
            head_ref: pr.head&.ref,
            base_ref: pr.base&.ref,
            head_repository: pr.head&.repo&.full_name,
            fork_pr: !we_control_head?(pr),
            marker: marker,
            classification_enabled: DeliveryPolicy.for(repository: repository).external_pr_ingest_classification_enabled?
          }
        )
      rescue Octokit::NotFound
        Mcp::Tools.invalid("pull request not found: ##{pr_number}")
      rescue Octokit::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def we_control_head?(pr)
        pr.head&.repo&.full_name == pr.base&.repo&.full_name
      end
    end
  end
end
