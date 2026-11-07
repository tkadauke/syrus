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

  it "returns only the changed subscription when toggling a repository" do
    subscription = OperatorBriefing::BriefingSubscription.create!(user: user, repository: repository, enabled: true)

    patch "/api/v1/app/briefing/subscriptions/#{subscription.id}",
          params: { subscription: { enabled: false } },
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("subscription", "id")).to eq(subscription.id)
    expect(response.parsed_body.dig("subscription", "enabled")).to eq(false)
    expect(response.parsed_body.keys).to contain_exactly("subscription")
  end

  it "updates a source preference by creating a new confirmed preference" do
    preference = OperatorBriefing::SourcePreference.effective_for_user(user).fetch("spend")

    patch "/api/v1/app/briefing/source_preferences/#{preference.id}",
          params: { source_preference: { enabled: false } },
          as: :json

    expect(response).to have_http_status(:ok)
    expect(OperatorBriefing::SourcePreference.effective_for_user(user).fetch("spend")).not_to be_enabled
    expect(response.parsed_body.dig("source_preference", "source_key")).to eq("spend")
    expect(response.parsed_body.dig("source_preference", "enabled")).to eq(false)
    expect(response.parsed_body).not_to have_key("repositories")
  end

  it "confirms a pending AI source preference suggestion" do
    suggestion = OperatorBriefing::SourcePreference.suggest!(user: user, source_key: "spend", enabled: false)

    post "/api/v1/app/briefing/source_preferences/#{suggestion.id}/confirm", as: :json

    expect(response).to have_http_status(:ok)
    expect(suggestion.reload.confirmed_at).to be_present
    expect(suggestion.suggested_by).to eq("ai")
    expect(OperatorBriefing::SourcePreference.effective_for_user(user).fetch("spend")).not_to be_enabled
    expect(response.parsed_body.dig("source_preference", "id")).to eq(suggestion.id)
  end

  it "creates feedback and a linked memory entry" do
    post "/api/v1/app/briefing/feedback",
         params: { feedback: { briefing_id: briefing.id, sentiment: "positive", note: "More of this." } },
         as: :json

    expect(response).to have_http_status(:created)
    feedback = OperatorBriefing::Feedback.sole
    expect(feedback.memory_entry).to be_present
    expect(response.parsed_body.dig("feedback", "memory_entry_id")).to eq(feedback.memory_entry_id)
    expect(response.parsed_body).not_to have_key("briefing")
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
    expect(response.parsed_body.keys).to contain_exactly("workflow_id", "status")
  end

  it "loads archived briefing content only from the history endpoint" do
    job.close_with_reason!("briefing_superseded") if job.may_close?
    briefing.revisions.create!(
      revision_number: 1,
      generated_at: Time.current,
      content_blocks: [ { "kind" => "narrative", "payload" => { "text" => "Archived detail" } } ]
    )
    OperatorBriefing::BriefingSubscription.create!(user: user, repository: repository, enabled: true)

    get "/api/v1/app/briefing"

    history_stub = response.parsed_body.fetch("repositories").sole.fetch("history").sole
    expect(history_stub).not_to have_key("latest_revision")

    get "/api/v1/app/briefing/history", params: { briefing_id: briefing.id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("briefing", "latest_revision", "content_blocks", 0, "payload", "text")).to eq("Archived detail")
  end

  it "paginates topic revisions three at a time" do
    topic = OperatorBriefing::BriefingTopic.create!(repository: repository, slug: "architecture", title: "Architecture")
    5.times do |index|
      topic.revisions.create!(revision_number: index + 1, generated_at: Time.current, narrative: "Revision #{index + 1}")
    end

    get "/api/v1/app/briefing/topics/#{topic.id}"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("revisions").pluck("revision_number")).to eq([ 5, 4, 3 ])
    expect(response.parsed_body.fetch("next_cursor")).to eq(3)

    get "/api/v1/app/briefing/topics/#{topic.id}", params: { cursor: 3 }

    expect(response.parsed_body.fetch("revisions").pluck("revision_number")).to eq([ 2, 1 ])
    expect(response.parsed_body.fetch("next_cursor")).to be_nil
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
    expect(chat.messages.sole.content.fetch("text")).to include("Briefing: BRIEFING-#{briefing.id}.")
  end
end
