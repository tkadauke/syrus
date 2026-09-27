require "rails_helper"
require "tmpdir"

RSpec.describe OperatorBriefing::GenerateRunStep do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low") }
  let(:workflow) { OperatorBriefing::Workflow.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "briefing_generate_run") }
  let(:run) { Run.create!(job: job, user: user, step: step, trigger_kind: "briefing_generate", agent_provider: user.agent_provider) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("operator-briefing-generate-run") do |dir|
      @workspace_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    allow(AppUserChannel).to receive(:broadcast_to)
    allow(handler).to receive(:workspace).and_return(instance_double(WorkflowWorkspace, setup: nil, path: @workspace_path))
    allow(handler).to receive(:run_agent) do |prompt:, required_mcp_tools:, **_kwargs|
      @agent_prompt = prompt
      @required_mcp_tools = required_mcp_tools
      submit_candidate_blocks(handler)
    end
    @briefing = OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: 1.day.ago,
      window_end: 1.hour.from_now
    )
  end

  it "creates a structured revision with narrative and link-card blocks" do
    recent_job = Job.create!(user: user, owner_user: user, repository: repository, kind: "direct", issue_number: nil, issue_title: "Refine auth", priority: "low")
    OperatorBriefing::WorkflowNotableChange.create!(
      workflow: workflow,
      job: job,
      repository: repository,
      detector_key: "schema",
      fact_key: "schema:test",
      severity: "decision_required",
      summary: "Schema changed",
      evidence: []
    )

    handler.call

    revision = @briefing.revisions.sole
    expect(revision.generation_run).to eq(run)
    expect(revision.content_blocks.map { |block| block.fetch("kind") }).to include("narrative", "link_card")
    expect(revision.content_blocks.to_json).to include("Refine auth", "Schema changed")
    expect(AppUserChannel).to have_received(:broadcast_to).with(user, hash_including("resource" => "operator_briefing")).at_least(:once)
    expect(@required_mcp_tools).to eq(%w[submit_briefing_block])
    expect(@agent_prompt).to include("Call `submit_briefing_block` once per final block")
    expect(@agent_prompt).to include("Refine auth", "Schema changed")
  end

  it "omits cards and counts for disabled sources" do
    OperatorBriefing::SourcePreference.seed_for_user!(user)
    OperatorBriefing::SourcePreference.create!(
      user: user,
      source_key: "jobs",
      enabled: false,
      weight: 1.0,
      suggested_by: "user",
      confirmed_at: Time.current
    )
    Job.create!(user: user, owner_user: user, repository: repository, kind: "direct", issue_number: nil, issue_title: "Refine auth", priority: "low")

    handler.call

    revision = @briefing.revisions.sole
    expect(revision.content_blocks.to_json).not_to include("Refine auth")
    expect(revision.content_blocks.first.dig("payload", "text")).to include("No notable activity")
    expect(revision.content_blocks.first.dig("payload", "text")).not_to include("1 recent Jobs")
  end

  it "loads user preference memories into the generation payload" do
    AgentMemory::Entry.create!(
      user: user,
      kind: "user_pref",
      scope: "global",
      content: "Operator prefers fewer spend items.",
      confidence: 0.9
    )

    handler.call

    revision = @briefing.revisions.sole
    expect(revision.content_blocks.first.dig("payload", "personalization_memory_context"))
      .to include("Operator prefers fewer spend items.")
  end

  it "fails if the synthesis agent does not stream any blocks" do
    allow(handler).to receive(:run_agent)

    expect { handler.call }
      .to raise_error(Steps::Base::StepFailed, "agent didn't call submit_briefing_block")
  end

  def submit_candidate_blocks(handler)
    handler.send(:content_blocks, @briefing).each do |block|
      OperatorBriefing::Tools::SubmitBriefingBlockTool.call(
        kind: block.fetch("kind"),
        payload: block.fetch("payload"),
        server_context: { run_id: run.id }
      )
    end
  end
end
