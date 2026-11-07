require "rails_helper"

RSpec.describe "App API review notes", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_with_run(user: user, repository: repo, step_attrs: { kind: "post_implementation_review" }) }
  let(:run) { job.initial_run }
  let(:workflow) { job.latest_workflow }
  let!(:version) do
    DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base-sha",
      head_sha: "head-sha",
      files: []
    )
  end

  before do
    PluginRecord.find_or_create_by!(name: "cognitive_review").update!(enabled: true, default_enabled: false, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    allow(User).to receive(:chat_providers).and_return(%w[claude])
    sign_in_as(user)
  end

  def parse_body = JSON.parse(response.body)
  def notes_path(record = job) = "/api/v1/app/jobs/#{record.id}/review_notes"
  def legacy_notes_path(record = job) = "/api/v1/app/jobs/#{record.id}/cognitive_review_notes"
  def note_path(note, record = job) = "#{notes_path(record)}/#{note.id}"

  def create_note(**attrs)
    CognitiveReview::Note.create!({
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/widget.rb",
      side: "new",
      start_line: 12,
      end_line: 14,
      title: "State transition edge",
      explanation: "Operator should inspect whether the new transition is reachable.",
      reason_codes: %w[state],
      confidence: 0.82,
      priority: "high",
      source_metadata: {}
    }.merge(attrs))
  end

  it "returns long note detail only from the show endpoint" do
    reader = Factories.user
    RepositoryMembership.create!(repository: repo, user: reader, role: "read")
    note = create_note(source_metadata: { "provider" => "codex" })
    sign_in_as(reader)

    get note_path(note)

    expect(response).to have_http_status(:ok)
    expect(parse_body["note"]).to include(
      "id" => note.id,
      "explanation" => note.explanation,
      "source_metadata" => { "provider" => "codex" }
    )
  end

  it "does not expose the unused note collection routes" do
    note = create_note

    get notes_path
    expect(response).to have_http_status(:not_found)

    get legacy_notes_path
    expect(response).to have_http_status(:not_found)

    get "#{legacy_notes_path}/#{note.id}"
    expect(response).to have_http_status(:ok)
  end

  it "acknowledges an open note as handled review-note debt" do
    note = create_note

    post "#{note_path(note)}/acknowledge"

    expect(response).to have_http_status(:ok)
    expect(note.reload).to have_attributes(state: "acknowledged", acknowledged_by_user: user)
    expect(parse_body["note"]).to include("id" => note.id, "state" => "acknowledged")
    expect(parse_body["note"]).not_to have_key("explanation")
    expect(parse_body).not_to have_key("debt_rollup")
  end

  it "starts discussion and records the operator message as a handled note range" do
    note = create_note

    post "#{note_path(note)}/discussion_entries", params: { body: "Let's inspect this edge.", metadata: { source: "review_tab" } }, as: :json

    expect(response).to have_http_status(:created)
    expect(note.reload).to have_attributes(state: "discussed", discussion_started_by_user: user, last_discussed_by_user: user)
    expect(note.discussion_entries.last).to have_attributes(user: user, body: "Let's inspect this edge.")
    expect(parse_body["note"]).to include("id" => note.id, "state" => "discussed")
  end

  it "starts an agent discussion chat for a note without writing a discussion entry" do
    note = create_note
    discussion_entry_count = CognitiveReview::DiscussionEntry.count

    expect {
      post "#{note_path(note)}/start_discussion", params: { message: "Please inspect the lifecycle edge before changing this." }, as: :json
    }.to change(ChatSession, :count).by(1)
      .and change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTurnJob).with(kind_of(Integer), kind_of(Integer))

    expect(response).to have_http_status(:ok)
    expect(CognitiveReview::DiscussionEntry.count).to eq(discussion_entry_count)
    expect(note.reload).to have_attributes(state: "discussed", discussion_started_by_user: user, last_discussed_by_user: user)
    chat = job.reload.discussion_chat
    expect(parse_body["redirect_to"]).to eq("/chats/#{chat.id}")
    expect(chat.messages.sole.content["text"]).to include(
      "Discuss this Review Note with the operator.",
      "Location: #{note.path}:#{note.start_line}-#{note.end_line} (#{note.side}).",
      note.title,
      note.explanation,
      "Operator prompt:",
      "Please inspect the lifecycle edge before changing this."
    )
    expect(parse_body["note"]).to include("id" => note.id, "state" => "discussed")
    expect(parse_body["note"]).not_to have_key("explanation")
  end

  it "reopens an already-discussed note chat without creating a duplicate message or turn" do
    note = create_note
    chat = ChatSession.create!(user: user, repository: repo)
    job.chat_attachments.create!(chat_session: chat)
    note.start_discussion!(user: user)
    discussed_at = note.last_discussed_at

    expect {
      post "#{note_path(note)}/start_discussion", params: { message: "Do not send this twice." }, as: :json
    }.not_to change(ChatMessage, :count)

    expect(response).to have_http_status(:ok)
    expect(ChatSession.count).to eq(1)
    expect(ChatTurnJob).not_to have_been_enqueued
    expect(note.reload).to have_attributes(state: "discussed", last_discussed_at: discussed_at)
    expect(parse_body["redirect_to"]).to eq("/chats/#{chat.id}")
  end

  it "reuses the chat attached by a concurrent discussion winner" do
    note = create_note
    winning_chat = nil
    allow_any_instance_of(CognitiveReview::Note).to receive(:start_discussion!) do |record, user:|
      record.update!(
        state: "discussed",
        discussion_started_at: Time.current,
        discussion_started_by_user: user,
        last_discussed_at: Time.current,
        last_discussed_by_user: user
      )
      winning_chat = ChatSession.create!(user: user, repository: repo)
      job.chat_attachments.create!(chat_session: winning_chat)
      false
    end
    message_count = ChatMessage.count

    expect {
      post "#{note_path(note)}/start_discussion", params: { message: "Please inspect this." }, as: :json
    }.to change(ChatSession, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(ChatMessage.count).to eq(message_count)
    expect(job.reload.discussion_chat).to eq(winning_chat)
    expect(parse_body["redirect_to"]).to eq("/chats/#{winning_chat.id}")
    expect(ChatTurnJob).not_to have_been_enqueued
  end

  it "blocks read-tier repository members from acknowledging notes" do
    reader = Factories.user
    RepositoryMembership.create!(repository: repo, user: reader, role: "read")
    note = create_note
    sign_in_as(reader)

    post "#{note_path(note)}/acknowledge"

    expect(response).to have_http_status(:forbidden)
    expect(note.reload.state).to eq("open")
  end

  it "returns plugin_disabled while the plugin route is disabled" do
    note = create_note
    PluginRecord.find_by!(name: "cognitive_review").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    get note_path(note)

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end
end
