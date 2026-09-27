require "rails_helper"

RSpec.describe "Operator briefing personalization API", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "direct", issue_number: nil, issue_title: "Briefing fixture", priority: "low") }
  let!(:briefing) do
    OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: 1.day.ago,
      window_end: Time.current
    )
  end

  before do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    sign_in_as(user)
  end

  it "serializes source preferences on the briefing payload" do
    get "/api/v1/app/briefing"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("source_preferences").map { |row| row.fetch("source_key") })
      .to include("jobs", "spend")
  end

  it "updates a source preference by creating a new confirmed preference" do
    preference = OperatorBriefing::SourcePreference.effective_for_user(user).fetch("spend")

    patch "/api/v1/app/briefing/source_preferences/#{preference.id}",
          params: { source_preference: { enabled: false } },
          as: :json

    expect(response).to have_http_status(:ok)
    expect(OperatorBriefing::SourcePreference.effective_for_user(user).fetch("spend")).not_to be_enabled
    expect(response.parsed_body.fetch("source_preferences").find { |row| row.fetch("source_key") == "spend" }.fetch("enabled")).to eq(false)
  end

  it "confirms a pending AI source preference suggestion" do
    suggestion = OperatorBriefing::SourcePreference.suggest!(user: user, source_key: "spend", enabled: false)

    post "/api/v1/app/briefing/source_preferences/#{suggestion.id}/confirm", as: :json

    expect(response).to have_http_status(:ok)
    expect(suggestion.reload.confirmed_at).to be_present
    expect(suggestion.suggested_by).to eq("ai")
    expect(OperatorBriefing::SourcePreference.effective_for_user(user).fetch("spend")).not_to be_enabled
  end

  it "creates feedback and a linked memory entry" do
    post "/api/v1/app/briefing/feedback",
         params: { feedback: { briefing_id: briefing.id, sentiment: "positive", note: "More of this." } },
         as: :json

    expect(response).to have_http_status(:created)
    feedback = OperatorBriefing::Feedback.sole
    expect(feedback.memory_entry).to be_present
    expect(response.parsed_body.dig("feedback", "memory_entry_id")).to eq(feedback.memory_entry_id)
  end

  it "starts a briefing dive workflow with the selected text context" do
    allow(WorkUnits::Launcher).to receive(:create_and_start!) do |kind:, job:, artifacts:, **|
      workflow = OperatorBriefing::DiveWorkflow.instantiate(job: job, artifacts: artifacts)
      instance_double(WorkUnits::Launcher::Result, workflow: workflow, status: "started")
    end

    post "/api/v1/app/briefing/#{briefing.id}/dive",
         params: {
           dive: {
             selected_text: "architecture change",
             prompt: "Explain this",
             evidence: [ { workflow_id: 123 } ]
           }
         },
         as: :json

    expect(response).to have_http_status(:created)
    expect(WorkUnits::Launcher).to have_received(:create_and_start!).with(
      kind: "briefing_dive",
      job: job,
      artifacts: hash_including(
        "briefing_dive_context" => hash_including(
          "briefing_id" => briefing.id,
          "selected_text" => "architecture change",
          "prompt" => "Explain this",
          "evidence" => [ { "workflow_id" => 123 } ]
        )
      )
    )
  end

  it "opens a briefing discussion chat with context" do
    allow(User).to receive(:chat_providers).and_return(%w[claude])

    expect {
      post "/api/v1/app/briefing/#{briefing.id}/discuss", as: :json
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(1)

    expect(response).to have_http_status(:ok)
    chat = ChatSession.last
    expect(response.parsed_body.fetch("redirect_to")).to eq("/chats/#{chat.id}")
    expect(chat.messages.sole.content.fetch("text")).to include("Context: discuss the Operator Briefing for #{repository.slug}.")
  end
end
