require "rails_helper"

RSpec.describe Mcp::Tools::ReadLiveStateTool do
  let(:run) { Factories.job.initial_run }

  def call(detail: "compact", context: { run_id: run.id })
    described_class.call(detail: detail, server_context: context)
  end

  def payload_from(response)
    JSON.parse(response.content.first[:text])
  end

  def captured_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA"
      next if payload[:cached]

      queries << payload[:sql].to_s
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    queries
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

    it "batches related chat counts while keeping recent messages bounded" do
      high_count_chat = ChatSession.create!(user: run.job.user, repository: run.job.repository, title: "Long planning")
      job_chat = ChatSession.create!(user: run.job.user, repository: run.job.repository, title: "Job feedback")
      job_chat.chat_attachments.create!(attachable: run.job)
      quiet_chat = ChatSession.create!(user: run.job.user, repository: run.job.repository, title: "Quiet chat")

      now = Time.current
      ChatMessage.insert_all!(
        125.times.map do |index|
          {
            chat_session_id: high_count_chat.id,
            role: index.even? ? "user" : "assistant",
            content: { "text" => "Message #{index}" },
            created_at: now + index.seconds,
            updated_at: now + index.seconds
          }
        end
      )
      2.times do |index|
        job_chat.messages.create!(role: "user", content: { "text" => "Job note #{index}" })
      end
      high_count_chat.update_columns(last_message_at: now + 125.seconds)
      job_chat.update_columns(last_message_at: now + 124.seconds)
      quiet_chat.update_columns(last_message_at: now + 123.seconds)
      high_count_chat.pending_actions.create!(action: "cancel_job", payload: { "job_id" => run.job.id })
      job_chat.pending_actions.create!(action: "retry_job", payload: { "job_id" => run.job.id })
      job_chat.pending_actions.create!(action: "cancel_job", payload: { "job_id" => run.job.id }, state: "confirmed")

      response = nil
      queries = captured_sql { response = call(detail: "full") }
      payload = payload_from(response)
      sessions = payload.dig("chat", "sessions").index_by { |session| session["id"] }

      expect(sessions.fetch(high_count_chat.id)["message_count"]).to eq(125)
      expect(sessions.fetch(high_count_chat.id)["pending_actions_count"]).to eq(1)
      expect(sessions.fetch(high_count_chat.id)["recent_messages"].size).to eq(3)
      expect(sessions.fetch(job_chat.id)["message_count"]).to eq(2)
      expect(sessions.fetch(job_chat.id)["pending_actions_count"]).to eq(1)
      expect(sessions.fetch(quiet_chat.id)["message_count"]).to eq(0)
      expect(sessions.fetch(quiet_chat.id)["pending_actions_count"]).to eq(0)

      message_count_queries = queries.grep(/SELECT COUNT\(\*\).*FROM "?chat_messages"?/i)
      pending_action_count_queries = queries.grep(/SELECT COUNT\(\*\).*FROM "?chat_pending_actions"?/i)
      recent_message_queries = queries.grep(/FROM "?chat_messages"?/i) - message_count_queries
      attachment_queries = queries.grep(/FROM "?chat_attachments"?/i)

      expect(message_count_queries.size).to eq(1)
      expect(pending_action_count_queries.size).to eq(1)
      expect(recent_message_queries.size).to be <= SyrusMcp::LiveState::RELATED_CHAT_LIMIT
      expect(attachment_queries.size).to be <= 2
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

    it "samples unfinished RunJob rows before applying the live-state limit" do
      ensure_solid_queue_test_tables!
      101.times do |index|
        SolidQueue::Job.create!(
          active_job_id: "finished-run-job-#{index}",
          class_name: "RunJob",
          queue_name: "runs",
          priority: 10,
          created_at: (index + 1).minutes.ago,
          updated_at: (index + 1).minutes.ago,
          scheduled_at: (index + 1).minutes.ago,
          finished_at: index.seconds.ago,
          arguments: { "arguments" => [ run.id + index + 1000 ] }
        )
      end
      SolidQueue::Job.create!(
        active_job_id: "active-run-job-#{run.id}",
        class_name: "RunJob",
        queue_name: "runs",
        priority: 10,
        created_at: 2.days.ago,
        updated_at: 2.days.ago,
        scheduled_at: 2.days.ago,
        arguments: { "arguments" => [ run.id ] }
      )

      payload = payload_from(call)

      entries = payload.dig("queue", "solid_queue", "run_job_entries")
      expect(entries.size).to eq(1)
      expect(payload.dig("queue", "solid_queue", "sampled_run_job_count")).to eq(1)
      expect(payload.dig("queue", "solid_queue", "note")).to include("unfinished RunJob")
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

    it "has an index for the unfinished RunJob live-state lookup" do
      ensure_solid_queue_test_tables!

      expect(ActiveRecord::Base.connection.index_exists?(
        :solid_queue_jobs,
        [ :class_name, :finished_at, :created_at ],
        name: "index_solid_queue_jobs_on_class_finished_created_at"
      )).to be(true)
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end
  end
end
