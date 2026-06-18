require "rails_helper"

RSpec.describe SyrusChatMcp::SubmitChatFeedbackTool do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments)
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "submit_chat_feedback", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "queues a chat_feedback workflow for an implemented job" do
    job = Factories.job_record(repository: repository, state: "implemented")

    expect {
      @response = call_tool(job_id: job.id, feedback: "Please tighten the retry explanation.")
    }.to have_enqueued_job(RunJob)

    body = payload(@response)
    workflow = job.workflows.find(body[:workflow_id])

    expect(@response.dig(:result, :isError)).to be_falsey
    expect(body).to include(trigger_kind: "chat_feedback")
    expect(body[:message]).to eq("Feedback submitted. Workflow ##{workflow.id} has been queued.")
    expect(workflow).to have_attributes(trigger_kind: "chat_feedback", agent_provider: job.agent_provider)
    expect(workflow.artifact("chat_feedback")).to eq("Please tighten the retry explanation.")
    expect(workflow.steps.map(&:kind)).to include("respond", "summarize_amend", "push")
  end

  it "rejects jobs outside the chat repository" do
    other_job = Factories.job_record(repository: Factories.repository(user: user), state: "implemented")

    response = call_tool(job_id: other_job.id, feedback: "Adjust this.")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("job not found in this repository")
  end

  it "rejects jobs in a non-actionable state" do
    job = Factories.job_record(repository: repository, state: "triaging")

    response = call_tool(job_id: job.id, feedback: "Adjust this.")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("triaging jobs are not actionable")
    expect(job.workflows.where(trigger_kind: "chat_feedback")).to be_empty
  end

  it "rejects duplicate active chat_feedback workflows" do
    job = Factories.job_record(repository: repository, state: "implemented")
    Workflow.create!(job: job, trigger_kind: "chat_feedback", state: "running")

    response = call_tool(job_id: job.id, feedback: "Adjust this.")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("chat_feedback workflow is already queued or running")
    expect(job.workflows.where(trigger_kind: "chat_feedback").count).to eq(1)
  end

  it "unapproves an approved job after queuing feedback" do
    job = Factories.job_record(repository: repository, state: "approved", approved_at: Time.current)

    call_tool(job_id: job.id, feedback: "Adjust this before landing.")

    expect(job.reload).to be_implemented
    expect(job.approved_at).to be_nil
  end
end
