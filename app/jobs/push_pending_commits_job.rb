class PushPendingCommitsJob < ApplicationJob
  queue_as :default

  # Push any committed changes from a failed Workflow's workspace to
  # GitHub, staging and committing any remaining uncommitted edits
  # first. Idempotent: stamps commits_pushed_at in the workflow's
  # artifacts on success; subsequent enqueues are no-ops.
  def perform(workflow_id)
    workflow = Workflow.find(workflow_id)
    return if workflow.artifact("commits_pushed_at")

    path = WorkflowWorkspace.path_for(workflow)
    return unless path.exist?

    job       = workflow.job
    push_url  = job.repository.authenticated_push_url(GithubClient.for(repository: job.repository, user: job.user).access_token)
    git       = GitRunner.new
    push_env  = { "GIT_TERMINAL_PROMPT" => "0" }
    identity  = BotIdentity.for(job)
    commit_env = {
      "GIT_AUTHOR_NAME"     => identity.git_name,
      "GIT_AUTHOR_EMAIL"    => identity.git_email,
      "GIT_COMMITTER_NAME"  => identity.git_name,
      "GIT_COMMITTER_EMAIL" => identity.git_email
    }

    # Stage and commit any uncommitted changes before pushing.
    status = git.run("status", "--porcelain", chdir: path.to_s)
    if status.strip.present?
      git.run("add", "-A", chdir: path.to_s)
      message = identity.append_co_authored_by("Unfinished work from Syrus agent (operator-pushed)")
      git.run("commit", "-m", message,
              chdir: path.to_s, env: commit_env)
    end

    branch_name = git.run("rev-parse", "--abbrev-ref", "HEAD", chdir: path.to_s).strip
    git.run("push", push_url, "HEAD:refs/heads/#{branch_name}",
            chdir: path.to_s, env: push_env)

    workflow.set_artifact!("commits_pushed_at",     Time.current.iso8601)
    workflow.set_artifact!("commits_pushed_branch", branch_name)
  end
end
