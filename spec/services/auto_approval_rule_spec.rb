require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe AutoApprovalRule do
  let(:user) { Factories.user }
  # auto_merge_enabled so the landing-queue blockage check passes;
  # otherwise LandingQueueProcessor.try_land! refuses to dispatch
  # the AutoMerge workflow and the Job stays :approved instead of
  # progressing to :landing.
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repo, syrus_yml:)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml)
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repo)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  def build_grade_context(job)
    # The workflow must be in a terminal state so it doesn't count as
    # "active workflow" in LandingQueueProcessor#blockage_for. Setting
    # the grader step + run to :succeeded matches what a real
    # post-grade-success state would look like.
    workflow = Workflow.create!(job: job, trigger_kind: "initial",
                                 agent_provider: job.agent_provider, state: "succeeded")
    step = Step.create!(workflow: workflow, kind: "grade", state: "succeeded", position: 0)
    Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, agent_provider: job.agent_provider, state: "succeeded")
    workflow.set_artifact!("grade_plan_source", ".syrus.yml")
    workflow.set_artifact!("grade_plan_repo_committed", true)
    step
  end

  def approvable_job(**attrs)
    # pr_number required so landing-queue blockage check passes (no
    # PR = no merge target). Same reasoning as auto_merge_enabled.
    Factories.job_record(**{ user: user, repository: repository, state: "queued",
                              pr_number: 100 + rand(10_000) }.merge(attrs))
  end

  it "auto-approves, lands, AND dispatches an AutoMerge workflow when repo-committed graders pass" do
    # Epic#releases_jobs_for_execution? is true only when state is
    # in_progress / done. Otherwise blocked_by_epic_before_execution?
    # blocks landing-queue dispatch.
    epic = Factories.epic(user: user, repository: repository, auto_approve_mode: "if_graders_pass", state: "in_progress")
    job = approvable_job(epic: epic)
    step = build_grade_context(job)

    result = described_class.for(job).apply_after_grader_success!(step)

    expect(result).to be_approved
    expect(job.reload.state).to eq("landing")
    expect(job.approved_via).to eq("auto_rule")
    expect(job.approval_evidence).to eq(
      "rule" => "if_graders_pass",
      "source" => "Epic##{epic.number}",
      "grader_step_id" => step.id
    )
    expect(job.current_run.job_logs.last.chunk).to include("auto_approval: approved via if_graders_pass")
    # Regression: the previous `@job.land!` transitioned state to
    # :landing but never instantiated the AutoMerge workflow, jamming
    # the landing queue with a stuck Job. Now LandingQueueProcessor.try_land!
    # dispatches the workflow inline.
    expect(job.workflows.where(trigger_kind: "auto_merge").count).to eq(1)
  end

  it "auto-approves cron jobs from the originating ScheduledTask rule" do
    task = ScheduledTask.create!(
      user: user,
      repository: repository,
      name: "Daily intake",
      prompt: "Ingest issues.",
      kind: "cron",
      cron_expression: "0 9 * * *",
      pr_pileup_policy: "skip",
      auto_approve_mode: "if_graders_pass"
    )
    job = approvable_job(kind: "cron", issue_number: nil, scheduled_task: task)
    step = build_grade_context(job)

    described_class.for(job).apply_after_grader_success!(step)

    expect(job.reload.state).to eq("landing")
    expect(job.approval_evidence["source"]).to eq("ScheduledTask##{task.id}")
    expect(job.workflows.where(trigger_kind: "auto_merge").count).to eq(1)
  end

  it "lands auto-approved cron jobs even when .syrus.yml requires owner approval" do
    write_bare_clone(repository, syrus_yml: <<~YAML)
      approval:
        job:
          required:
            owner: true
    YAML
    task = ScheduledTask.create!(
      user: user,
      repository: repository,
      name: "Log sift",
      prompt: "Sift through logs and fix things.",
      kind: "cron",
      cron_expression: "0 9 * * *",
      pr_pileup_policy: "skip",
      auto_approve_mode: "if_graders_pass"
    )
    job = approvable_job(kind: "cron", issue_number: nil, scheduled_task: task)
    step = build_grade_context(job)

    result = described_class.for(job).apply_after_grader_success!(step)

    expect(result).to be_approved
    expect(job.reload.state).to eq("landing")
    expect(job.approved_via).to eq("auto_rule")
    expect(job.job_approvals).to be_empty
    expect(job.workflows.where(trigger_kind: "auto_merge").count).to eq(1)
  end

  it "resolves ScheduledTask before Epic before repository before user before never" do
    epic = Factories.epic(user: user, repository: repository, auto_approve_mode: "if_graders_pass")
    task = ScheduledTask.create!(
      user: user,
      repository: repository,
      name: "Daily intake",
      prompt: "Ingest issues.",
      kind: "cron",
      cron_expression: "0 9 * * *",
      pr_pileup_policy: "skip",
      auto_approve_mode: "if_graders_pass_and_tagged_safe"
    )
    user.update!(auto_approve_mode: "if_graders_pass")
    repository.update!(auto_approve_mode: "if_graders_pass_and_tagged_safe")

    cron_job = approvable_job(kind: "cron", issue_number: nil, scheduled_task: task, epic: epic)
    expect(described_class.for(cron_job).resolved_mode).to eq([ "if_graders_pass_and_tagged_safe", "ScheduledTask##{task.id}" ])

    epic_job = approvable_job(issue_number: 43, epic: epic)
    expect(described_class.for(epic_job).resolved_mode).to eq([ "if_graders_pass", "Epic##{epic.number}" ])

    epic.update!(auto_approve_mode: "never")
    expect(described_class.for(epic_job.reload).resolved_mode).to eq([ "if_graders_pass_and_tagged_safe", "Repository##{repository.id}" ])

    repository.update!(auto_approve_mode: "never")
    expect(described_class.for(epic_job.reload).resolved_mode).to eq([ "if_graders_pass", "User##{user.id}" ])

    user.update!(auto_approve_mode: "never")
    expect(described_class.for(epic_job.reload).resolved_mode).to eq([ "never", nil ])
  end

  it "does not approve when the grader source changed during the run" do
    epic = Factories.epic(user: user, repository: repository, auto_approve_mode: "if_graders_pass")
    job = approvable_job(epic: epic)
    step = build_grade_context(job)
    step.workflow.set_artifact!("grade_plan_repo_committed", false)

    result = described_class.for(job).apply_after_grader_success!(step)

    expect(result).not_to be_approved
    expect(result.reason).to eq("grader_not_repo_committed")
    expect(job.reload.state).to eq("queued")
    expect(job.approved_via).to be_nil
  end

  # Regression: when an auto_merge prerequisite is missing
  # (repository.auto_merge_enabled = false, archived repo, etc.) the
  # rule used to call @job.land! unconditionally — leaving the Job
  # stuck in :landing without an AutoMerge workflow, jamming the
  # landing queue. Now the Job correctly stays in :approved;
  # LandingQueueProcessor's recurring tick will pick it up if/when
  # the blockage clears.
  it "stays in :approved (no stuck :landing) when the AutoMerge prerequisites aren't met" do
    repository.update!(auto_merge_enabled: false)
    epic = Factories.epic(user: user, repository: repository, auto_approve_mode: "if_graders_pass")
    job = approvable_job(epic: epic)
    step = build_grade_context(job)

    result = described_class.for(job).apply_after_grader_success!(step)

    expect(result).to be_approved
    expect(job.reload.state).to eq("approved")
    expect(job.approved_via).to eq("auto_rule")
    expect(job.workflows.where(trigger_kind: "auto_merge")).to be_empty
  end

  it "requires a safe tag for if_graders_pass_and_tagged_safe" do
    epic = Factories.epic(user: user, repository: repository, auto_approve_mode: "if_graders_pass_and_tagged_safe", state: "in_progress")
    job = approvable_job(epic: epic)
    step = build_grade_context(job)

    result = described_class.for(job).apply_after_grader_success!(step)

    expect(result.reason).to eq("safe_tag_missing")
    expect(job.reload.state).to eq("queued")

    job.tags << Factories.tag(user: user, name: "safe")
    described_class.for(job).apply_after_grader_success!(step)

    expect(job.reload.state).to eq("landing")
  end
end
