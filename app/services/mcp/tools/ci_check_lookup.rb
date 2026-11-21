module Mcp::Tools
  # Shared resolution for the CI read tools: which repository and commit an
  # agent may inspect, and the check runs on it. Reads go through Syrus's own
  # GitHub credentials for the Job's repository, so agents never need a token
  # or the gh CLI -- which would let them act outside the harness -- to see why
  # CI failed.
  module CiCheckLookup
    Target = Data.define(:repository, :client, :pr_number, :sha)

    module_function

    def target(server_context, pr_number: nil)
      return Mcp::Tools.invalid("CI checks can only be read from a workflow run with a Job") unless server_context[:run_id] || server_context[:run]

      run = Mcp::Tools.run_from_context(server_context)
      job = run&.job
      return Mcp::Tools.invalid("CI checks can only be read from a workflow run with a Job") unless job

      context = McpToolContext.from_run(run)

      repository = job.repository
      number = pr_number.presence&.to_i || job.pr_number || job.external_pr_number
      return Mcp::Tools.invalid("#{job.slug} has no pull request yet; there is no CI to read") unless number.to_i.positive?

      client = GithubClient.for(repository: repository, user: context.user || job.user)
      pr = client.pull_request(repository.slug, number)
      sha = pr.respond_to?(:head) ? pr.head&.sha : nil
      return Mcp::Tools.invalid("pull request ##{number} has no head commit") if sha.blank?

      Target.new(repository:, client:, pr_number: number, sha:)
    rescue Octokit::NotFound
      Mcp::Tools.invalid("pull request not found: #{number}")
    rescue ArgumentError, Octokit::Error => e
      Mcp::Tools.invalid(e.message)
    end

    def checks(target)
      target.client.ci_checks_for(target.repository.slug, target.sha)
    end
  end
end
