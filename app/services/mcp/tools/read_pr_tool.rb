require "mcp"

module Mcp::Tools
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
        return Mcp::Tools.invalid("pr_number must be positive") unless pr_number.positive?

        # GitHub reads use the chat user's credentials for this repository, not
        # a shared token, so private PR access follows the same user boundary.
        client = GithubClient.for(repository: repository, user: chat_session.user)
        pr = client.pull_request(repository.slug, pr_number)
        diff = content_diff(repository, chat_session.user, pr) || client.pull_request_diff(repository.slug, pr_number)

        Mcp::Tools.success(
          pr: {
            number: pr.number,
            title: pr.title,
            body: pr.body.to_s,
            state: pr.state,
            html_url: pr.html_url,
            diff: Mcp::Tools.truncate_text(diff, Prompts::PullRequestSummary::MAX_DIFF_BYTES)
          }
        )
      rescue Octokit::NotFound
        Mcp::Tools.invalid("pull request not found: #{pr_number}")
      rescue ArgumentError, Octokit::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      # The PR's diff from repository content -- the git mirror when it has
      # both commits -- as unified diff text. nil when it cannot be read in
      # full (a commit the mirror lacks, GitHub's 300-file cap), so the caller
      # asks GitHub for the diff instead of showing part of one.
      def content_diff(repository, user, pr)
        base_sha = pr.respond_to?(:base) ? pr.base&.sha : nil
        head_sha = pr.respond_to?(:head) ? pr.head&.sha : nil
        return nil if base_sha.blank? || head_sha.blank?

        content = RepositoryContent.for(repository, user: user)
        changes = content.changes(base: content.resolve(base_sha), head: content.resolve(head_sha), patch: true)
        changes.map { |change| unified(change) }.join
      rescue RepositoryContent::Error
        nil
      end

      def unified(change)
        old_path = change.previous_path || change.path
        header = +"diff --git a/#{old_path} b/#{change.path}\n"
        header << "--- #{change.status == 'added' ? '/dev/null' : "a/#{old_path}"}\n"
        header << "+++ #{change.status == 'deleted' ? '/dev/null' : "b/#{change.path}"}\n"
        return header + "Binary files differ\n" if change.patch.nil? && change.status != "renamed"

        header + change.patch.to_s + (change.patch.to_s.end_with?("\n") || change.patch.nil? ? "" : "\n")
      end
    end
  end
end
