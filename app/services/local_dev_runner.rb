require "digest/sha1"
require "fileutils"
require "open3"
require "pathname"
require "securerandom"

class LocalDevRunner
  Result = Data.define(:job, :workflow, :diff)

  def self.call(...)
    new(...).call
  end

  def initialize(path:, prompt:, output: nil, workflow: "local_dev", user: nil,
                 agent_provider: nil, stdout: $stdout)
    @raw_path = path
    @path = path.present? ? Pathname.new(path).expand_path : nil
    @prompt = prompt.to_s
    @output = output
    @workflow_name = workflow.to_s
    @user = user
    @agent_provider = agent_provider
    @stdout = stdout
  end

  def call
    validate!

    root = git("rev-parse", "--show-toplevel").strip
    default_branch = current_branch
    user = @user || default_user
    repository = local_repository_for(user, root, default_branch)
    job = create_job(user, repository, root)
    workflow = instantiate_workflow(job, root)
    run = start_without_enqueue(workflow)

    RunJob.perform_now(run.id)
    workflow.reload
    raise "local dev workflow failed (state=#{workflow.state})" unless workflow.succeeded?

    diff = workflow.steps.find_by(kind: "implement").latest_run.agent_diff.to_s
    write_diff(diff)
    Result.new(job: job.reload, workflow: workflow, diff: diff)
  end

  private

  def validate!
    raise ArgumentError, "path is required" if @raw_path.to_s.blank?
    raise ArgumentError, "prompt is required" if @prompt.strip.blank?
    raise ArgumentError, "unsupported workflow: #{@workflow_name}" unless @workflow_name == "local_dev"
    if @agent_provider.present? && !User::AGENT_PROVIDERS.include?(@agent_provider)
      raise ArgumentError, "unsupported agent provider: #{@agent_provider}"
    end
    raise ArgumentError, "path is not a directory: #{@path}" unless @path.directory?

    inside = git("rev-parse", "--is-inside-work-tree").strip
    raise ArgumentError, "path is not inside a git work tree: #{@path}" unless inside == "true"
  end

  def current_branch
    branch = git("branch", "--show-current").strip
    raise ArgumentError, "local checkout must be on a branch" if branch.blank?

    branch
  end

  def default_user
    User.order(:id).first || User.create!(
      email_address: "local-dev@syrus.invalid",
      password: SecureRandom.hex(16),
      agent_provider: @agent_provider.presence || "claude"
    )
  end

  def local_repository_for(user, root, default_branch)
    name = local_repository_name(root)
    repository = user.repositories.find_or_initialize_by(owner: "local", name: name)
    repository.default_branch = default_branch
    repository.trigger_label = "local"
    repository.polling_enabled = false
    repository.agent_provider = @agent_provider.presence if @agent_provider.present?
    repository.save!
    repository
  end

  def local_repository_name(root)
    basename = File.basename(root).gsub(/[^a-zA-Z0-9._-]/, "-")
    basename = "repo" if basename.blank? || basename !~ /\A[a-zA-Z0-9]/
    "#{basename}-#{Digest::SHA1.hexdigest(root)[0, 8]}"
  end

  def create_job(user, repository, root)
    job = user.jobs.create!(
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Local dev: #{root}",
      issue_body: @prompt,
      priority: "medium",
      agent_provider: @agent_provider.presence || repository.effective_agent_provider
    )
    job.update!(branch_name: "syrus/local-#{job.id}")
    job
  end

  def instantiate_workflow(job, root)
    Workflows.for(trigger_kind: @workflow_name).instantiate(
      job: job,
      artifacts: { "local_source_path" => root }
    )
  end

  def start_without_enqueue(workflow)
    Thread.current[:syrus_in_run_job] = true
    StepDispatcher.start_workflow(workflow)
    workflow.first_step.runs.first
  ensure
    Thread.current[:syrus_in_run_job] = nil
  end

  def write_diff(diff)
    if @output.present?
      output_path = Pathname.new(@output).expand_path
      FileUtils.mkdir_p(output_path.dirname)
      File.write(output_path, diff)
    else
      @stdout.write(diff)
      @stdout.write("\n") unless diff.end_with?("\n")
    end
  end

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", @path.to_s, *args)
    raise ArgumentError, "git #{args.join(' ')} failed: #{err.presence || out}" unless status.success?

    out
  end
end
