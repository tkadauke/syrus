require "rails_helper"

RSpec.describe SyrusMcp::ReadLiveStateTool do
  let(:run) { Factories.job.initial_run }

  def call(detail: "compact", context: { run_id: run.id })
    described_class.call(detail: detail, server_context: context)
  end

  def payload_from(response)
    JSON.parse(response.content.first[:text])
  end

  describe ".call" do
    it "serializes compact live state for the active run context" do
      response = call

      expect(response).not_to be_error
      payload = payload_from(response)
      expect(payload["detail"]).to eq("compact")
      expect(payload.dig("job", "id")).to eq(run.job_id)
      expect(payload.dig("job", "repository")).to eq(run.job.repository.slug)
      expect(payload.dig("workflow", "id")).to eq(run.workflow_id)
      expect(payload.dig("run", "id")).to eq(run.id)
      expect(payload.dig("worker_health_correlation", "run_id")).to eq(run.id)
      expect(payload.dig("links", "api_run_transcript")).to eq("/api/v1/admin/runs/#{run.id}/transcript")
      expect(payload).to include("queue", "chat")
      expect(payload).not_to include("recent_workflows")
    end

    it "supports full detail with recent workflows and chat message snippets" do
      chat = ChatSession.create!(user: run.job.user, title: "Job council")
      chat.chat_attachments.create!(attachable: run.job)
      chat.messages.create!(role: "user", content: { "text" => "What is happening?" })
      chat.messages.create!(role: "assistant", content: { "text" => "The aqueduct is under inspection." })

      response = call(detail: "full")
      payload = payload_from(response)

      expect(payload["detail"]).to eq("full")
      expect(payload["recent_workflows"].first["id"]).to eq(run.workflow_id)
      session = payload.dig("chat", "sessions").first
      expect(session["id"]).to eq(chat.id)
      expect(session["message_count"]).to eq(2)
      expect(session["recent_messages"].map { |message| message["role"] }).to eq(%w[user assistant])
    end

    it "includes Solid Queue entries for the current run when queue tables are available" do
      ensure_solid_queue_test_tables!
      SolidQueue::Job.create!(
        active_job_id: "run-job-#{run.id}",
        class_name: "RunJob",
        queue_name: "runs",
        priority: 10,
        scheduled_at: Time.current,
        arguments: { "arguments" => [ run.id ] }
      )
      SolidQueue::Job.create!(
        active_job_id: "other-run-job",
        class_name: "RunJob",
        queue_name: "runs",
        priority: 10,
        scheduled_at: Time.current,
        arguments: { "arguments" => [ run.id + 1000 ] }
      )

      payload = payload_from(call)

      entries = payload.dig("queue", "solid_queue", "run_job_entries")
      expect(entries.size).to eq(1)
      expect(entries.first["queue_name"]).to eq("runs")
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    it "returns a tool error for an invalid run context" do
      response = call(context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe "schema surface" do
    it "exposes only the optional detail selector" do
      expect(described_class.tool_name).to eq("read_live_state")
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to be_blank
      expect(schema[:properties].keys).to eq([ :detail ])
    end
  end
end
