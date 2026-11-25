require "rails_helper"

RSpec.describe Mcp::Tools::DetachJobTool do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin, default_branch: "main") }
  let(:chat) { ChatSession.create!(user: admin, repository: repository) }
  let(:job) { Factories.job_record(user: admin, repository: repository, issue_number: 10068, pr_number: 10068, branch_name: "syrus/child", state: "implemented") }
  let(:context) { { chat_session: chat } }
  let(:plan) do
    {
      "job_id" => job.id,
      "workflow_ids" => [ 44 ],
      "pr_number" => 10068,
      "current_branch_head" => "a" * 40,
      "live_pr_base" => "syrus/parent",
      "inferred_parent_job_id" => 10066,
      "destination_base" => "main",
      "commits_to_preserve" => [ { "sha" => "a" * 40, "message" => "owned change" } ],
      "patches_to_preserve" => [ { "path" => "app/example.rb", "status" => "modified", "patch" => "@@" } ],
      "expected_topology" => { "parent_job_id" => nil, "pr_base" => "main", "branch" => "syrus/child" }
    }
  end

  before { allow(JobDetachPlan).to receive(:for).and_return(plan) }

  it "returns diagnosis evidence without creating a pending action for dry-run" do
    response = described_class.call(job_id: job.id, destination_base: "main", dry_run: true, server_context: context)

    expect(response).to be_a(MCP::Tool::Response)
    expect(chat.pending_actions.where(action: "detach_job")).to be_empty
    expect(JobDetachPlan).to have_received(:for).with(job, destination_base: "main")
  end

  it "requires a reason and creates an operator-confirmed repair request" do
    message = ChatMessage.create!(chat_session: chat, role: "assistant", content: {})
    server_context = context.merge(current_message: message)

    response = described_class.call(job_id: job.id, destination_base: "main", reason: "Repair accidental stack parent.", server_context: server_context)

    expect(response).to be_a(MCP::Tool::Response)
    action = chat.pending_actions.find_by!(action: "detach_job")
    expect(action).to have_attributes(reason: "Repair accidental stack parent.", state: "pending")
    expect(action.payload).to include("job_id" => job.id, "destination_base" => "main", "plan" => plan)
  end
end
