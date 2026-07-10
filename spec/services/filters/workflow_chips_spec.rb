require "rails_helper"

RSpec.describe "Filters::Chips::Workflows" do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def job(issue_number = SecureRandom.random_number(10_000) + 1)
    Factories.job_record(repository: repo, issue_number: issue_number)
  end

  def workflow(**attrs)
    Workflow.create!({
      job: attrs.delete(:job) || job,
      trigger_kind: "initial",
      agent_provider: "claude"
    }.merge(attrs))
  end

  def step_for(workflow, **attrs)
    Step.create!({
      workflow: workflow,
      kind: "implement",
      position: workflow.steps.count
    }.merge(attrs))
  end

  def run_for(workflow, **attrs)
    step = attrs.delete(:step) || step_for(workflow)
    Run.create!({
      job: workflow.job,
      step: step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    }.merge(attrs))
  end

  def run_filter(field:, op:, value: nil)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => field, "op" => op, "value" => value),
      scope: Workflow.joins(:job).where(jobs: { repository_id: repo.id }),
      user: user,
      subject: :workflow
    )
  end

  describe "subject registration" do
    it "registers the Workflow subject and chip map" do
      subject = Filters::SUBJECTS[:workflow]

      expect(subject.model).to eq(Workflow)
      expect(subject.chips).to include(
        "state" => "Filters::Chips::Workflows::State",
        "is_stuck" => "Filters::Chips::Workflows::IsStuck",
        "attention" => "Filters::Chips::Workflows::Attention"
      )
    end

    it "serializes a Workflow schema for the chip bar" do
      schema = Filters::Schema.for(subject: :workflow, user: user)
      by_field = schema.index_by { |chip| chip["field"] }

      expect(by_field["state"]["values"].map { |v| v["value"] }).to eq(%w[ queued running succeeded failed cancelled ])
      expect(by_field["trigger_kind"]["values"].map { |v| v["value"] }).to include("initial", "pr_comment")
      expect(by_field["trigger_kind"]["values"].map { |v| v["value"] }).not_to include("resume")
      expect(by_field["agent_provider"]["values"].map { |v| v["value"] }).to eq(User.agent_providers)
      expect(by_field["run_count"]["bucket"]).to eq("number")
      expect(by_field["attention"]["expansions"]).to include("stuck", "just_failed")
    end
  end

  describe "state" do
    it "filters by workflow state" do
      running = workflow(state: "running")
      workflow(state: "queued")

      expect(run_filter(field: "state", op: "is", value: "running")).to contain_exactly(running)
    end
  end

  describe "trigger_kind" do
    it "filters by trigger kind" do
      retry_workflow = workflow(trigger_kind: "retry")
      workflow(trigger_kind: "initial")

      expect(run_filter(field: "trigger_kind", op: "is", value: "retry")).to contain_exactly(retry_workflow)
    end
  end

  describe "job_id" do
    it "filters by parent job id" do
      parent = job(101)
      match = workflow(job: parent)
      workflow

      expect(run_filter(field: "job_id", op: "is", value: parent.id)).to contain_exactly(match)
    end
  end

  describe "agent_provider" do
    it "filters by agent provider" do
      codex = workflow(agent_provider: "codex")
      workflow(agent_provider: "claude")

      expect(run_filter(field: "agent_provider", op: "is", value: "codex")).to contain_exactly(codex)
    end
  end

  describe "started_at" do
    it "filters by start time" do
      recent = workflow(started_at: 30.minutes.ago)
      workflow(started_at: 3.days.ago)

      expect(run_filter(field: "started_at", op: "within_last", value: { "n" => 1, "unit" => "hours" })).to contain_exactly(recent)
    end
  end

  describe "finished_at" do
    it "filters by finish time" do
      finished = workflow(state: "succeeded", finished_at: 20.minutes.ago)
      workflow(state: "running", finished_at: nil)

      expect(run_filter(field: "finished_at", op: "is_set")).to contain_exactly(finished)
    end
  end

  describe "failure_reason" do
    it "filters by failure reason text" do
      exhausted = workflow(state: "failed", failure_reason: "loop exhausted after grader failure")
      workflow(state: "failed", failure_reason: "push failed")

      expect(run_filter(field: "failure_reason", op: "contains", value: "grader")).to contain_exactly(exhausted)
    end
  end

  describe "has_failed_steps" do
    it "matches workflows with failed steps" do
      failed = workflow
      step_for(failed, state: "failed")
      step_for(workflow, state: "succeeded")

      expect(run_filter(field: "has_failed_steps", op: "is_true")).to contain_exactly(failed)
    end
  end

  describe "is_stuck" do
    it "matches running workflows whose latest run heartbeat is stale" do
      stuck = workflow(state: "running")
      run_for(stuck, state: "running", last_heartbeat_at: 31.minutes.ago, started_at: 40.minutes.ago)
      fresh = workflow(state: "running")
      run_for(fresh, state: "running", last_heartbeat_at: 5.minutes.ago, started_at: 10.minutes.ago)
      old_finished = workflow(state: "failed")
      run_for(old_finished, state: "failed", last_heartbeat_at: 31.minutes.ago, started_at: 40.minutes.ago)

      expect(run_filter(field: "is_stuck", op: "is_true")).to contain_exactly(stuck)
    end
  end

  describe "run_count" do
    it "filters by total runs in the workflow" do
      many = workflow
      step = step_for(many)
      2.times { run_for(many, step: step) }
      one = workflow
      run_for(one)

      expect(run_filter(field: "run_count", op: "greater_than", value: 1)).to contain_exactly(many)
    end
  end

  describe "attention presets" do
    it "running: returns running workflows" do
      running = workflow(state: "running")
      workflow(state: "queued")

      expect(run_filter(field: "attention", op: "is", value: "running")).to contain_exactly(running)
    end

    it "stuck: returns running workflows with stale latest run heartbeat" do
      stuck = workflow(state: "running")
      run_for(stuck, state: "running", last_heartbeat_at: 31.minutes.ago)
      fresh = workflow(state: "running")
      run_for(fresh, state: "running", last_heartbeat_at: 5.minutes.ago)

      expect(run_filter(field: "attention", op: "is", value: "stuck")).to contain_exactly(stuck)
    end

    it "just_failed: returns workflows failed within the last hour" do
      recent = workflow(state: "failed", finished_at: 30.minutes.ago)
      workflow(state: "failed", finished_at: 2.hours.ago)

      expect(run_filter(field: "attention", op: "is", value: "just_failed")).to contain_exactly(recent)
    end

    it "queued: returns queued workflows" do
      queued = workflow(state: "queued")
      workflow(state: "running")

      expect(run_filter(field: "attention", op: "is", value: "queued")).to contain_exactly(queued)
    end

    it "interrupted: returns cancelled workflows whose latest run recorded worker death" do
      interrupted = workflow(state: "cancelled")
      run_for(interrupted, state: "failed", agent_outcome: "worker_died")
      cancelled = workflow(state: "cancelled")
      run_for(cancelled, state: "cancelled", agent_outcome: "operator_cancelled")

      expect(run_filter(field: "attention", op: "is", value: "interrupted")).to contain_exactly(interrupted)
    end
  end
end
