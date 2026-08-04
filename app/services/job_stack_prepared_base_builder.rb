require "fileutils"
require "set"

class JobStackPreparedBaseBuilder
  Result = Data.define(:succeeded, :reason, :branch_name, :head_sha, :dependencies, :message) do
    def succeeded? = succeeded

    def to_h
      {
        "succeeded" => succeeded?,
        "reason" => reason,
        "branch_name" => branch_name,
        "head_sha" => head_sha,
        "dependencies" => dependencies,
        "message" => message
      }.compact
    end
  end

  def initialize(job, workflow, git: nil)
    @job = job
    @workflow = workflow
    @repository = job.repository
    @git = git || GitRunner.new
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def call(dependency_jobs)
    @dependency_jobs = topological_order(dependency_jobs)
    return failure("no_dependencies", "no dependency jobs supplied") if @dependency_jobs.empty?

    clone_base_branch
    configure_git_author
    fetch_and_validate_dependencies
    merge_dependencies
    push_prepared_branch

    Result.new(
      true,
      "prepared",
      prepared_branch,
      head_sha,
      dependency_payloads,
      "prepared fan-in execution base from #{dependency_jobs.size} dependency branches"
    )
  rescue GitRunner::GitError => e
    abort_merge
    failure("merge_conflict_or_git_error", e.message)
  rescue StandardError => e
    failure("error", "#{e.class}: #{e.message}")
  ensure
    cleanup_clone
  end

  private

  attr_reader :job, :workflow, :repository, :dependency_jobs

  def clone_path
    @clone_path ||= WorkflowWorkspace.data_root.join("prepared-stack-bases", "#{job.id}-#{workflow.id}")
  end

  def authenticated_url
    @authenticated_url ||= repository.authenticated_url(user: job.user)
  end

  def push_url
    authenticated_url
  end

  def prepared_branch
    "syrus/prepared-base-#{job.id}-#{workflow.id}"
  end

  def clone_base_branch
    FileUtils.mkdir_p(clone_path.dirname)
    authenticated_git("git_prepared_base_clone") do |url|
      @git.run("clone", "--branch", job.base_default_branch, "--no-tags", url, clone_path.to_s, env: @env)
    end
    @git.run("remote", "set-url", "origin", repository.remote_url, chdir: clone_path.to_s)
    @git.run("checkout", "-B", prepared_branch, chdir: clone_path.to_s)
  end

  def configure_git_author
    @git.configure_author(BotIdentity.for(job), chdir: clone_path.to_s)
  end

  def fetch_and_validate_dependencies
    dependency_jobs.each do |dependency|
      ref = remote_ref_for(dependency)
      authenticated_git("git_prepared_base_fetch") do |url|
        @git.run(
          "fetch",
          url,
          "+refs/heads/#{dependency.branch_name}:#{ref}",
          chdir: clone_path.to_s,
          env: @env
        )
      end
      fetched_sha = @git.run("rev-parse", ref, chdir: clone_path.to_s).strip
      expected_sha = expected_head_sha_for(dependency)
      next if expected_sha.blank? || fetched_sha == expected_sha

      raise "dependency #{dependency.slug} branch #{dependency.branch_name} moved from #{expected_sha} to #{fetched_sha}"
    end
  end

  def merge_dependencies
    dependency_jobs.each do |dependency|
      @git.run(
        "merge",
        "--no-edit",
        "--no-ff",
        remote_ref_for(dependency),
        chdir: clone_path.to_s,
        env: @env
      )
    end
  end

  def push_prepared_branch
    authenticated_git("git_prepared_base_push") do |url|
      @git.run("push", url, "HEAD:refs/heads/#{prepared_branch}", chdir: clone_path.to_s, env: @env)
    end
  end

  def abort_merge
    return unless clone_path&.exist?

    @git.run("merge", "--abort", chdir: clone_path.to_s)
  rescue GitRunner::GitError
    nil
  end

  def cleanup_clone
    FileUtils.rm_rf(clone_path) if clone_path
  end

  def head_sha
    @git.run("rev-parse", "HEAD", chdir: clone_path.to_s).strip
  end

  def remote_ref_for(dependency)
    "refs/remotes/origin/#{dependency.branch_name}"
  end

  def authenticated_git(operation_type, &block)
    @authenticated_url = nil
    GithubAuthenticatedGit.run(repository: repository, user: job.user, git: @git, operation_type: operation_type, &block)
  end

  def topological_order(jobs)
    records = jobs.compact.uniq.sort_by(&:id)
    by_id = records.index_by(&:id)
    visited = Set.new
    ordered = []

    visit = lambda do |node|
      next if visited.include?(node.id)

      visited << node.id
      node.dependencies.includes(:depends_on_job).map(&:depends_on_job).compact.sort_by(&:id).each do |parent|
        visit.call(parent) if by_id.key?(parent.id)
      end
      ordered << node
    end

    records.each { |record| visit.call(record) }
    ordered
  end

  def dependency_payloads
    dependency_jobs.map do |dependency|
      {
        "job_id" => dependency.id,
        "slug" => dependency.slug,
        "branch_name" => dependency.branch_name,
        "head_sha" => expected_head_sha_for(dependency)
      }
    end
  end

  def expected_head_sha_for(dependency)
    dependency.mergeability_head_sha.presence || dependency.head_sha.to_s.presence
  end

  def failure(reason, message)
    Result.new(false, reason, nil, nil, dependency_payloads, message)
  end
end
