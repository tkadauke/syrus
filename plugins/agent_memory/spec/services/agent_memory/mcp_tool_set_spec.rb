require "rails_helper"

RSpec.describe AgentMemory::McpToolSet do
  let(:job) { Factories.job }

  before do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: true, disableable: true)
  end

  def context_for(role)
    instance_double(McpToolContext, role: role)
  end

  def run_for_step(kind)
    step = Step.create!(workflow: job.latest_workflow, kind: kind, position: 99)
    step.runs.create!(job: job, trigger_kind: job.latest_workflow.trigger_kind)
  end

  def tool_names_for(role)
    described_class.tool_definitions(context: context_for(role)).map { |definition| definition[:name] }
  end

  it "keeps read-only memory tools visible to adversarial reviewers" do
    expect(tool_names_for(AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER)).to include(
      "read_memory",
      "search_memories",
      "list_memories"
    )
  end

  it "keeps read-only memory tools visible to visual reviewers" do
    expect(tool_names_for(AgentRole::WORKFLOW_VISUAL_REVIEWER)).to include(
      "read_memory",
      "search_memories",
      "list_memories"
    )
  end

  it "does not advertise mutating memory tools to reviewer roles" do
    [
      AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
      AgentRole::WORKFLOW_VISUAL_REVIEWER
    ].each do |role|
      expect(tool_names_for(role)).not_to include("write_memory", "delete_memory")
    end
  end

  it "advertises mutating memory tools to normal implementation runs" do
    expect(tool_names_for(AgentRole::WORKFLOW_IMPLEMENT)).to include("write_memory", "delete_memory")
  end

  it "rejects denied reviewer calls before dispatching write_memory" do
    run = run_for_step("adversarial_review")

    expect {
      response = described_class.new.handle(
        "write_memory",
        { "content" => "Review-only agents cannot persist this.", "kind" => "feedback" },
        { run: run }
      )

      expect(response).to be_error
      expect(response.content.first[:text]).to include("Unknown Agent Memory tool")
    }.not_to change(AgentMemory::Entry, :count)
  end

  it "rejects denied reviewer calls before dispatching delete_memory" do
    memory = AgentMemory::Entry.create!(
      user: job.user,
      kind: "feedback",
      scope: "repository",
      scope_id: job.repository_id,
      content: "Keep this memory."
    )
    run = run_for_step("visual_review")

    response = described_class.new.handle("delete_memory", { "id" => memory.id }, { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("Unknown Agent Memory tool")
    expect(memory.reload.deleted_at).to be_nil
  end
end
