require "rails_helper"

RSpec.describe OperatorBriefing::GenerateRunStep do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low") }
  let(:workflow) { OperatorBriefing::Workflow.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "briefing_generate_run") }
  let(:run) { Run.create!(job: job, user: user, step: step, trigger_kind: "briefing_generate", agent_provider: user.agent_provider) }

  before do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    allow(AppUserChannel).to receive(:broadcast_to)
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

    described_class.new(run).call

    revision = @briefing.revisions.sole
    expect(revision.generation_run).to eq(run)
    expect(revision.content_blocks.map { |block| block.fetch("kind") }).to include("narrative", "link_card")
    expect(revision.content_blocks.to_json).to include("Refine auth", "Schema changed")
    expect(AppUserChannel).to have_received(:broadcast_to).with(user, hash_including("resource" => "operator_briefing")).at_least(:once)
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

    described_class.new(run).call

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

    described_class.new(run).call

    revision = @briefing.revisions.sole
    expect(revision.content_blocks.first.dig("payload", "personalization_memory_context"))
      .to include("Operator prefers fewer spend items.")
  end
end
