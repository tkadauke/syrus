require "rails_helper"

RSpec.describe Mcp::Tools::ResetJobTool do
  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user:) }
  let(:chat_session) { ChatSession.create!(user:, repository:) }

  it "creates a descriptive pending action for an eligible Job" do
    job = Factories.job_record(user:, repository:, state: "failed", branch_name: "syrus/feature", pr_number: 12)

    response = described_class.call(job_id: job.id, reason: "Start clean", server_context: { chat_session: })
    body = JSON.parse(response.content.first[:text])

    expect(body).to include("state" => "pending", "reason" => "Start clean")
    expect(body.fetch("destroys")).to include("open_pr_number" => 12, "branch" => "syrus/feature")
    expect(ChatPendingAction.last).to have_attributes(action: "reset_job", reason: "Start clean")
  end

  it "refuses landing Jobs with the next valid action" do
    job = Factories.job_record(user:, repository:, state: "landing")

    response = described_class.call(job_id: job.id, reason: "Start clean", server_context: { chat_session: })

    expect(response.content.first[:text]).to include("cancel or finish landing")
    expect(ChatPendingAction.where(action: "reset_job")).to be_empty
  end
end
