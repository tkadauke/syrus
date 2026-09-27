require "rails_helper"

RSpec.describe OperatorBriefing::Workflow do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, repository: repository, owner_user: user, kind: "briefing_generate", priority: "low") }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  it "materializes prepare before briefing generation and leaves out auto-close" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.trigger_kind).to eq("briefing_generate")
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare briefing_generate_run])
    expect(Step::Kind.by_kind.fetch("briefing_generate_run").agentic).to eq(true)
    expect(Step::Kind.by_kind.fetch("briefing_generate_run").required_mcp_tools).to eq(%w[submit_briefing_block])
  end

  it "marks briefing generation as an agentic synthesis step" do
    entry = Step::Kind.by_kind.fetch("briefing_generate_run")

    expect(entry.agentic).to be(true)
    expect(entry.agent_role).to eq(AgentRole::WORKFLOW_SUMMARY_TEST_PLAN)
    expect(entry.required_mcp_tools).to eq(%w[submit_briefing_block])
  end

  it "materializes the briefing dive follow-up chain" do
    workflow = OperatorBriefing::DiveWorkflow.instantiate(job: job)

    expect(workflow.trigger_kind).to eq("briefing_dive")
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare briefing_dive_investigate submit_dive_report])
    expect(Step::Kind.by_kind.fetch("briefing_dive_investigate").required_mcp_tools)
      .to eq(%w[read_briefing])
    expect(Step::Kind.by_kind.fetch("submit_dive_report").required_mcp_tools)
      .to eq(%w[read_briefing list_briefing_topics read_briefing_topic submit_dive_report])
  end

  it "uses ordinary job lifecycle propagation for briefing dive failures" do
    parent_job = Factories.job_record(user: user, repository: repository, state: "running")
    workflow = OperatorBriefing::DiveWorkflow.instantiate(job: parent_job)
    investigate_step = workflow.steps.find_by!(kind: "briefing_dive_investigate")
    run = Run.create!(job: parent_job, step: investigate_step, trigger_kind: "briefing_dive", state: "failed")
    run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "agent exited 1")

    expect(Workflow::TriggerKind.owns_job_lifecycle?(workflow.trigger_kind)).to eq(false)
    expect(workflow.work_definition).not_to be_manages_own_job_lifecycle
    expect { StepDispatcher.fail_from(investigate_step) }
      .to change { parent_job.reload.state }.from("running").to("failed")
  end

  it "contributes an issueless infrastructure job kind and work definition" do
    expect(Job::Kind.infrastructure_values).to include("briefing_generate")
    expect(Job::Kind.issueless?("briefing_generate")).to be(true)
    expect(Job::Kind.investigable?("briefing_generate")).to be(true)

    definition = WorkDefinitions.for("briefing_generate")
    expect(definition).to be_a(OperatorBriefing::WorkDefinition)
    expect(definition).to be_infrastructure
    expect(definition.workflow_trigger_kind).to eq("briefing_generate")
    expect(definition.scope).to eq("repository")

    dive_definition = WorkDefinitions.for("briefing_dive")
    expect(dive_definition).to be_a(OperatorBriefing::DiveWorkDefinition)
    expect(dive_definition).to be_child
    expect(dive_definition).not_to be_manages_own_job_lifecycle
    expect(dive_definition.workflow_trigger_kind).to eq("briefing_dive")
  end
end
