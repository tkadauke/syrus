require "rails_helper"

RSpec.describe OperatorBriefing::McpToolSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let!(:operator_briefing_plugin) do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low") }
  let(:workflow) { OperatorBriefing::Workflow.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "briefing_generate_run") }
  let(:run) { Run.create!(job: job, user: user, step: step, trigger_kind: "briefing_generate", agent_provider: user.agent_provider) }
  let(:briefing) do
    OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: 1.day.ago,
      window_end: Time.current
    )
  end
  let!(:revision) do
    OperatorBriefing::BriefingRevision.create!(
      briefing: briefing,
      generation_run: run,
      revision_number: 1,
      generated_at: Time.current,
      content_blocks: []
    )
  end

  def context_for(step_kind)
    instance_double(McpToolContext, run?: true, run: instance_double(Run, step: instance_double(Step, kind: step_kind)))
  end

  it "advertises generation tools only for briefing generation runs" do
    expect(described_class.tool_definitions(context: context_for("briefing_generate_run")).map { |definition| definition[:name] })
      .to contain_exactly("submit_briefing_block", "read_briefing_git_diff", "list_briefing_recent_workflows")
    expect(described_class.tool_definitions(context: context_for("implement"))).to eq([])
  end

  it "advertises briefing topic tools only for dive report runs" do
    expect(described_class.tool_definitions(context: context_for("briefing_dive_investigate")).map { |definition| definition[:name] })
      .to eq(%w[read_briefing])
    expect(described_class.tool_definitions(context: context_for("submit_dive_report")).map { |definition| definition[:name] })
      .to eq(%w[read_briefing list_briefing_topics read_briefing_topic submit_dive_report])
  end

  it "reads the full briefing for the run anchor job" do
    revision.update!(
      content_blocks: [
        { "kind" => "narrative", "payload" => { "text" => "Full narrative context" } }
      ]
    )
    briefing.items.create!(
      severity: "decision_required",
      narrative: "The migration window needs a closer look.",
      evidence: [ { "workflow_id" => workflow.id } ]
    )
    other_job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    OperatorBriefing::Briefing.create!(
      job: other_job,
      repository: repository,
      owner_user: user,
      window_start: 2.days.ago,
      window_end: 1.day.ago
    )
    dive_workflow = OperatorBriefing::DiveWorkflow.instantiate(
      job: job,
      artifacts: { "briefing_dive_context" => { "briefing_id" => briefing.id } }
    )
    dive_step = dive_workflow.steps.find_by!(kind: "briefing_dive_investigate")
    dive_run = Run.create!(job: job, user: user, step: dive_step, trigger_kind: "briefing_dive", agent_provider: user.agent_provider)

    response = described_class.new.handle("read_briefing", {}, { run_id: dive_run.id })

    expect(response).not_to be_error, response.content.first[:text]
    result = JSON.parse(response.content.first[:text])
    expect(result.dig("briefing", "id")).to eq(briefing.id)
    expect(result.dig("briefing", "slug")).to eq("BRIEFING-#{briefing.id}")
    expect(result.dig("briefing", "job", "slug")).to eq(job.slug)
    expect(result.dig("briefing", "latest_revision", "content_blocks").first.dig("payload", "text")).to eq("Full narrative context")
    expect(result.dig("briefing", "items").sole).to include(
      "severity" => "decision_required",
      "narrative" => "The migration window needs a closer look.",
      "evidence" => [ { "workflow_id" => workflow.id } ]
    )
  end

  it "appends submitted blocks to the current generated revision" do
    response = described_class.new.handle(
      "submit_briefing_block",
      {
        "kind" => "narrative",
        "payload" => { "text" => "Live section" }
      },
      { run_id: run.id }
    )

    expect(response).not_to be_error
    expect(revision.reload.content_blocks).to eq([
      { "kind" => "narrative", "payload" => { "text" => "Live section" } }
    ])
  end

  it "rejects calls before the generation revision exists" do
    revision.destroy!

    response = described_class.new.handle(
      "submit_briefing_block",
      {
        "kind" => "narrative",
        "payload" => { "text" => "Too early" }
      },
      { run_id: run.id }
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("no active Operator Briefing revision")
  end

  it "creates a topic revision from a submitted dive report" do
    dive_workflow = OperatorBriefing::DiveWorkflow.instantiate(
      job: job,
      artifacts: {
        "briefing_dive_context" => {
          "briefing_id" => briefing.id,
          "selected_text" => "architecture change"
        }
      }
    )
    dive_step = dive_workflow.steps.find_by!(kind: "submit_dive_report")
    dive_run = Run.create!(job: job, user: user, step: dive_step, trigger_kind: "briefing_dive", agent_provider: user.agent_provider)

    response = described_class.new.handle(
      "submit_dive_report",
      {
        "title" => "Architecture change",
        "narrative" => "The architecture changed across several workflows.",
        "findings" => [ "One durable finding" ]
      },
      { run_id: dive_run.id }
    )

    expect(response).not_to be_error
    topic = OperatorBriefing::BriefingTopic.sole
    expect(topic.repository).to eq(repository)
    expect(topic.latest_revision.narrative).to include("architecture changed")
    expect(OperatorBriefing::BriefingTopicLink.sole).to have_attributes(topic: topic, briefing: briefing, workflow: dive_workflow)
    expect(dive_workflow.reload.artifact("briefing_dive_report")).to include("topic_id" => topic.id)
  end
end
