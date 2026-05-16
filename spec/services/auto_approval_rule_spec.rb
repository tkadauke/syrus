require "rails_helper"

RSpec.describe AutoApprovalRule do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def build_grade_context(job)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: job.agent_provider)
    step = Step.create!(workflow: workflow, kind: "grade", state: "succeeded", position: 0)
    Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, agent_provider: job.agent_provider, state: "succeeded")
    workflow.set_artifact!("grade_plan_source", ".syrus.yml")
    workflow.set_artifact!("grade_plan_repo_committed", true)
    step
  end

  def approvable_job(**attrs)
    Factories.job_record(**{ user: user, repository: repository, state: "queued" }.merge(attrs))
  end

  it "auto-approves and lands an Epic job when repo-committed graders pass" do
    epic = Factories.epic(user: user, repository: repository, auto_approve_mode: "if_graders_pass")
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

  it "requires a safe tag for if_graders_pass_and_tagged_safe" do
    epic = Factories.epic(user: user, repository: repository, auto_approve_mode: "if_graders_pass_and_tagged_safe")
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
