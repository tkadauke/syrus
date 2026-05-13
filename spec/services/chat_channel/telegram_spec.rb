require "rails_helper"

RSpec.describe ChatChannel::Telegram do
  let(:user) { Factories.user(telegram_chat_id: "123456") }
  let(:repo) { Factories.repository(user: user, allow_operator_chat: "telegram") }
  let(:job) { Factories.job(repository: repo, issue_number: 7) }
  let(:run) { job.current_run }
  let(:connection) { instance_double(Net::HTTP) }
  let(:http) { class_double(Net::HTTP) }

  def telegram_response(message_id:)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    allow(response).to receive(:body).and_return(
      JSON.generate("ok" => true, "result" => { "message_id" => message_id })
    )
    response
  end

  before do
    allow(http).to receive(:start).and_yield(connection)
  end

  it "sends a message to the user's Telegram DM and stores the returned thread id" do
    expect(connection).to receive(:request) do |request|
      expect(request.path).to eq("/botbot-token/sendMessage")
      payload = JSON.parse(request.body)
      expect(payload).to include(
        "chat_id" => "123456",
        "text" => "Can I rename the ancient button?",
        "disable_web_page_preview" => true
      )
      telegram_response(message_id: 99)
    end

    delivery = described_class.new(http: http, token: "bot-token").send_message(
      run: run,
      text: "Can I rename the ancient button?"
    )

    expect(delivery.thread_id).to eq("telegram:123456:99")
    expect(run.reload.operator_chat_thread_id).to eq("telegram:123456:99")
  end

  it "reuses the previous Telegram message for the same Job as a reply thread" do
    prior_run = run
    prior_run.update!(operator_chat_thread_id: "telegram:123456:41")
    followup = Run.create!(job: job, trigger_kind: "manual", agent_provider: "claude")

    expect(connection).to receive(:request) do |request|
      payload = JSON.parse(request.body)
      expect(payload["reply_parameters"]).to eq("message_id" => 41)
      telegram_response(message_id: 42)
    end

    described_class.new(http: http, token: "bot-token").send_message(run: followup, text: "Still blocked.")

    expect(followup.reload.operator_chat_thread_id).to eq("telegram:123456:42")
  end

  it "records an inbound reply and routes it through the resume workflow" do
    run.update!(
      state: "failed",
      finished_at: Time.current,
      operator_chat_thread_id: "telegram:123456:99"
    )
    ClaudeSession.create!(run: run, session_id: "claude-session-1", provider: "claude")

    expect {
      described_class.new(http: http, token: "bot-token").receive_update!(
        "message" => {
          "chat" => { "id" => 123456 },
          "reply_to_message" => { "message_id" => 99 },
          "text" => "Yes, rename it."
        }
      )
    }.to change { Workflow.where(trigger_kind: "resume").count }.by(1)

    resume_run = job.reload.current_run
    expect(run.reload.operator_chat_response).to eq("Yes, rename it.")
    expect(resume_run.trigger_kind).to eq("resume")
    expect(resume_run.parent_session_id).to eq("claude-session-1")
    expect(resume_run.prompt).to include("Yes, rename it.")
  end
end
