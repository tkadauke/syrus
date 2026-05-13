require "mcp"

module SyrusChatMcp
  class ReadPrTool < MCP::Tool
    tool_name "read_pr"

    description "Read a GitHub pull request title, body, and capped diff for this chat session's repository."

    input_schema(
      properties: {
        pr_number: { type: "integer", description: "GitHub pull request number." }
      },
      required: %w[pr_number]
    )

    class << self
      def call(pr_number:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        repository = chat_session.repository
        pr_number = pr_number.to_i
        return SyrusChatMcp.invalid("pr_number must be positive") unless pr_number.positive?

        client = GithubClient.for(repository: repository, user: chat_session.user)
        pr = client.pull_request(repository.slug, pr_number)
        diff = client.pull_request_diff(repository.slug, pr_number)

        SyrusChatMcp.success(
          pr: {
            number: pr.number,
            title: pr.title,
            body: pr.body.to_s,
            state: pr.state,
            html_url: pr.html_url,
            diff: SyrusChatMcp.truncate_text(diff, Prompts::PullRequestSummary::MAX_DIFF_BYTES)
          }
        )
      rescue Octokit::NotFound
        SyrusChatMcp.invalid("pull request not found: #{pr_number}")
      rescue ArgumentError, Octokit::Error => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
