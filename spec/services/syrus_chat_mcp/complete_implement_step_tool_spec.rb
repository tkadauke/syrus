require "rails_helper"

RSpec.describe SyrusChatMcp::CompleteImplementStepTool do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, mode: "coding") }

  def enable_coding_mode!
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
  end

  def call_tool
    described_class.call(server_context: { chat_session: chat_session })
  end

  def payload(result)
    JSON.parse(result.content.first[:text], symbolize_names: true)
  end

  context "when coding_mode is enabled and job is in coding state" do
    before { enable_coding_mode! }

    let(:job) do
      Factories.job_record(user: user, repository: repository,
                           state: "coding", linked_chat_id: chat_session.id)
    end

    before { job }

    it "releases the coding lock and fires a coding_handoff workflow" do
      result = call_tool
      data = payload(result)

      expect(data[:job_id]).to eq(job.id)
      expect(data[:workflow_id]).to be_present
      expect(data[:message]).to include("Graders are running")

      expect(job.reload).not_to be_coding
      expect(Workflow.find(data[:workflow_id]).trigger_kind).to eq("coding_handoff")
    end

    it "transitions the job to implemented (running after workflow starts)" do
      call_tool
      # The job is released from coding before the workflow starts
      # then workflow.start transitions it to running
      expect(job.reload.state).to be_in(%w[implemented running])
    end

    it "returns the job slug" do
      result = call_tool
      expect(payload(result)[:job_slug]).to include("JOB-")
    end
  end

  context "when coding_mode feature is disabled" do
    it "returns an error" do
      job = Factories.job_record(user: user, repository: repository,
                                 state: "coding", linked_chat_id: chat_session.id)
      job

      result = call_tool
      data = payload(result)

      expect(data[:status]).to eq("error")
      expect(data[:message]).to match(/coding_mode feature/)
    end
  end

  context "when chat is not in coding mode" do
    before { enable_coding_mode! }

    let(:chat_session) { ChatSession.create!(user: user, mode: "planning") }

    it "returns an error" do
      result = call_tool
      expect(payload(result)[:status]).to eq("error")
      expect(payload(result)[:message]).to match(/not in coding mode/)
    end
  end

  context "when no job is linked to the chat" do
    before { enable_coding_mode! }

    it "returns an error" do
      result = call_tool
      expect(payload(result)[:status]).to eq("error")
      expect(payload(result)[:message]).to match(/no job is linked/)
    end
  end

  context "when linked job is not in coding state" do
    before { enable_coding_mode! }

    it "returns an error" do
      job = Factories.job_record(user: user, repository: repository,
                                 state: "implemented", linked_chat_id: chat_session.id)
      job

      result = call_tool
      expect(payload(result)[:status]).to eq("error")
      expect(payload(result)[:message]).to match(/not in coding state/)
    end
  end

  describe "sidecar tool registration" do
    before { enable_coding_mode! }

    it "is included in tools when chat is in coding mode" do
      chat = ChatSession.create!(user: user, mode: "coding")
      tools = SyrusChatMcp::Sidecar.tools_for(chat)
      expect(tools).to include(described_class)
    end

    it "is excluded when chat is in planning mode" do
      chat = ChatSession.create!(user: user, mode: "planning")
      tools = SyrusChatMcp::Sidecar.tools_for(chat)
      expect(tools).not_to include(described_class)
    end

    it "is excluded when coding_mode feature is disabled" do
      Feature.find_by(slug: "coding_mode")&.update!(enabled: false)
      chat = ChatSession.create!(user: user, mode: "coding")
      tools = SyrusChatMcp::Sidecar.tools_for(chat)
      expect(tools).not_to include(described_class)
    end
  end
end
