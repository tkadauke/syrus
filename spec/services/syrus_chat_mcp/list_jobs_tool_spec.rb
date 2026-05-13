require "rails_helper"

RSpec.describe SyrusChatMcp::ListJobsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, trigger_label: "syrus") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_jobs", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "defaults to open jobs on the chat repository with a limit of 20" do
    open_job = Factories.job(repository: repository, issue_number: 101, issue_title: "Open")
    closed_job = Factories.job(repository: repository, issue_number: 102, issue_title: "Closed")
    closed_job.close_with_reason!("pr_merged")
    Factories.job(repository: Factories.repository(user: user), issue_number: 103)

    response = call_tool
    jobs = response_payload(response).fetch(:jobs)

    expect(response[:result][:isError]).to be_falsey
    expect(jobs.map { |job| job[:id] }).to eq([ open_job.id ])
  end

  it "filters closed jobs and caps the requested limit" do
    2.times do |i|
      job = Factories.job(repository: repository, issue_number: 200 + i)
      job.close_with_reason!("no_changes")
    end

    response = call_tool(state: "closed", limit: 1_000)
    jobs = response_payload(response).fetch(:jobs)

    expect(jobs.size).to eq(2)
    expect(jobs.all? { |job| job[:state] == "closed" }).to be(true)
  end

  it "supports persisted Syrus label filters" do
    skipped = Factories.job(repository: repository, issue_number: 301, skip_prepare: true)
    Factories.job(repository: repository, issue_number: 302)

    response = call_tool(label: Job::PREPARE_SKIP_LABEL)
    jobs = response_payload(response).fetch(:jobs)

    expect(jobs.map { |job| job[:id] }).to eq([ skipped.id ])
  end

  it "returns a tool error for labels that are not stored on Jobs" do
    response = call_tool(label: "bug")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("arbitrary issue labels are not stored")
  end
end
