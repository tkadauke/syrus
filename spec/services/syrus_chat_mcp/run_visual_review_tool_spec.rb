require "rails_helper"

RSpec.describe Mcp::Tools::RunVisualReviewTool do
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
      params: { name: "run_visual_review", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def stub_visual_review_plan(enabled:)
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: enabled, rounds: 1, source: ".syrus.yml", note: nil)
    )
  end

  it "creates a pending confirmation without queueing a workflow immediately" do
    job = Factories.job_record(repository: repository, state: "implemented")

    expect {
      @response = call_tool(job_id: job.id)
    }.not_to have_enqueued_job(RunJob)

    body = payload(@response)
    pending_action = chat_session.pending_actions.find(body[:pending_confirmation_id])

    expect(@response.dig(:result, :isError)).to be_falsey
    expect(body).to include(state: "pending")
    expect(pending_action).to be_pending
    expect(pending_action).to have_attributes(action: "run_visual_review", requested_by: "agent")
    expect(pending_action.payload).to eq("job_id" => job.id)
    expect(job.workflows.where(trigger_kind: "manual_visual_review")).to be_empty
  end

  it "includes focused instructions in the confirmation and resulting workflow" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(repository: repository, state: "implemented")
    instructions = "Scroll until the persistent diff file title is directly below the app header."

    response = call_tool(job_id: job.id, prompt: instructions)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(pending_action.payload).to eq("job_id" => job.id, "prompt" => instructions)

    pending_action.confirm!(user: user)

    expect(pending_action.reload.result.artifact("manual_visual_review_instructions")).to eq(instructions)
    expect(job.reload.workflows.where(trigger_kind: "chat_feedback")).to be_empty
    expect(pending_action.result.steps.where(kind: "implement")).to be_empty
  end

  it "rejects blank and oversized prompts" do
    job = Factories.job_record(repository: repository, state: "implemented")

    blank_response = call_tool(job_id: job.id, prompt: "  ")
    oversized_response = call_tool(job_id: job.id, prompt: "x" * 4_001)

    expect(blank_response.dig(:result, :isError)).to be(true)
    expect(blank_response.dig(:result, :content, 0, :text)).to include("prompt cannot be blank")
    expect(oversized_response.dig(:result, :isError)).to be(true)
    expect(oversized_response.dig(:result, :content, 0, :text)).to include("4000")
    expect(chat_session.pending_actions).to be_empty
  end

  it "queues a manual_visual_review workflow only after confirmation" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(repository: repository, state: "implemented")
    response = call_tool(job_id: job.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect {
      pending_action.confirm!(user: user)
    }.to have_enqueued_job(RunJob)

    workflow = pending_action.reload.result

    expect(pending_action).to be_confirmed
    expect(workflow).to have_attributes(trigger_kind: "manual_visual_review")
  end

  it "returns an error for an unknown job" do
    response = call_tool(job_id: -1)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("job not found")
  end
end
