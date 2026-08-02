require "rails_helper"

RSpec.describe Admin::ChatScopedEventObservabilityPayload do
  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 12, issue_title: "Repair main") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, title: "Supervisor", system_kind: "supervisor") }

  def scoped_event(**attrs)
    ChatScopedEvent.create!({
      chat_session: chat_session,
      repository: repository,
      job: job,
      source_kind: "workflow_failed",
      payload: { "summary" => "Workflow failed", "severity" => "critical" },
      created_at: Time.current,
      updated_at: Time.current
    }.merge(attrs))
  end

  it "summarizes recent evaluator decisions and failure reasons" do
    scoped_event(
      evaluator_state: "completed",
      evaluator_result: { "decision" => "no_op", "reason" => "duplicate event" },
      evaluated_at: 5.minutes.ago
    )
    scoped_event(
      delivery_state: "delivered",
      evaluator_state: "completed",
      evaluator_result: { "decision" => "respond", "reason" => "operator should know" },
      evaluated_at: 4.minutes.ago
    )
    failure = scoped_event(
      evaluator_state: "failed",
      evaluator_error: "JSON::ParserError: evaluator did not return JSON",
      evaluated_at: 3.minutes.ago
    )
    scoped_event(
      evaluator_state: "completed",
      evaluator_result: { "decision" => "act", "reason" => "old action" },
      created_at: 2.days.ago,
      updated_at: 2.days.ago,
      evaluated_at: 2.days.ago
    )

    payload = described_class.new.as_json

    expect(payload[:window_hours]).to eq(24)
    expect(payload[:total]).to eq(3)
    expect(payload[:by_state]).to include("completed" => 2, "failed" => 1)
    expect(payload[:by_decision]).to eq("no_op" => 1, "respond" => 1, "act" => 0)
    expect(payload[:failures].first).to include(
      "id" => failure.id,
      "error" => "JSON::ParserError: evaluator did not return JSON"
    )
    expect(payload[:recent].first).to include(
      "source_kind" => "workflow_failed",
      "summary" => "Workflow failed",
      "chat" => include("path" => "/chats/#{chat_session.id}"),
      "repository" => include("slug" => "acme/widgets"),
      "job" => include("slug" => "JOB-#{job.id}", "path" => "/jobs/#{job.id}")
    )
  end
end
