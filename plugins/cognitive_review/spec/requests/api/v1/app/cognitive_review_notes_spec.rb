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

  it "lists notes for the selected diff review version" do
    old_note = create_note
    latest_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: nil,
      base_sha: "base-sha-2",
      head_sha: "head-sha-2",
      files: []
    )
    create_note(diff_review_version: latest_version, path: "README.md")

    get notes_path, params: { diff_review_version_id: version.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["diff_review_version_id"]).to eq(version.id)
    expect(body["notes"].map { |note| note["id"] }).to eq([ old_note.id ])
    expect(body["debt_rollup"]).to include(
      "total_flagged_ranges" => 1,
      "open_unhandled_count" => 1,
      "handled_count" => 0,
      "dismissed_count" => 0,
      "zero_note_state" => false
    )
    expect(body.dig("by_path", "app/models/widget.rb", "new:12-14").first).to include(
      "id" => old_note.id,
      "state" => "open"
    )
  end

  it "allows read-tier repository members to list notes" do
    reader = Factories.user
    RepositoryMembership.create!(repository: repo, user: reader, role: "read")
    create_note
    sign_in_as(reader)

    get notes_path

    expect(response).to have_http_status(:ok)
    expect(parse_body["notes"].size).to eq(1)
  end

  it "keeps the legacy cognitive review notes route as an alias" do
    create_note

    get legacy_notes_path

    expect(response).to have_http_status(:ok)
    expect(parse_body["notes"].size).to eq(1)
  end

  it "acknowledges an open note as handled review-note debt" do
    note = create_note

    post "#{note_path(note)}/acknowledge"

    expect(response).to have_http_status(:ok)
    expect(note.reload).to have_attributes(state: "acknowledged", acknowledged_by_user: user)
    expect(parse_body).to include("unresolved_count" => 0, "handled_count" => 1)
    expect(parse_body["debt_rollup"]).to include(
      "open_unhandled_count" => 0,
      "acknowledged_count" => 1,
      "discussed_count" => 0,
      "user_commented_count" => 0,
      "handled_count" => 1
    )
  end

  it "starts discussion and records the operator message as a handled note range" do
    note = create_note

    post "#{note_path(note)}/discussion_entries", params: { body: "Let's inspect this edge.", metadata: { source: "review_tab" } }, as: :json

    expect(response).to have_http_status(:created)
    expect(note.reload).to have_attributes(state: "discussed", discussion_started_by_user: user, last_discussed_by_user: user)
    expect(note.discussion_entries.last).to have_attributes(user: user, body: "Let's inspect this edge.")
    expect(parse_body.dig("discussion_entry", "metadata")).to eq("source" => "review_tab")
    expect(parse_body["debt_rollup"]).to include(
      "open_unhandled_count" => 0,
      "acknowledged_count" => 0,
      "discussed_count" => 1,
      "user_commented_count" => 0,
      "handled_count" => 1
    )
  end

  it "starts an agent discussion chat for a note without writing a discussion entry" do
    note = create_note
    discussion_entry_count = CognitiveReview::DiscussionEntry.count

    expect {
      post "#{note_path(note)}/start_discussion", as: :json
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
      note.explanation
    )
    expect(parse_body["notes"].first).to include("id" => note.id, "state" => "discussed")
    expect(parse_body["debt_rollup"]).to include("open_unhandled_count" => 0, "discussed_count" => 1, "handled_count" => 1)
  end

  it "counts operator diff comments on covered ranges as handled" do
    note = create_note
    job.diff_review_comments.create!(
      user: user,
      diff_review_version: version,
      surface: "job_diff",
      anchor_kind: "line",
      path: note.path,
      side: "right",
      new_line: 13,
      body: "This regular review comment covers the note.",
      state: "draft"
    )

    get notes_path, params: { diff_review_version_id: version.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("unresolved_count" => 0, "handled_count" => 1)
    expect(parse_body["debt_rollup"]).to include(
      "open_unhandled_count" => 0,
      "user_commented_count" => 1,
      "handled_count" => 1
    )
  end

  it "returns a zero-note no-debt rollup when no ranges were flagged" do
    CognitiveReview::Artifact.append!(run: run, notes: [], diff_review_version: version)

    get notes_path, params: { diff_review_version_id: version.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body["debt_rollup"]).to include(
      "total_flagged_ranges" => 0,
      "open_unhandled_count" => 0,
      "handled_count" => 0,
      "user_commented_count" => 0,
      "dismissed_count" => 0,
      "submitted" => true,
      "zero_note_state" => true
    )
  end

  it "does not report zero-note no-debt without a submitted review result" do
    get notes_path, params: { diff_review_version_id: version.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body["debt_rollup"]).to include(
      "total_flagged_ranges" => 0,
      "submitted" => false,
      "zero_note_state" => false
    )
  end

  it "counts user comments on covered note ranges as handled" do
    note = create_note
    DiffReviewComment.create!(
      job: job,
      diff_review_version: version,
      user: user,
      surface: "job_source_diff",
      anchor_kind: "line",
      path: note.path,
      side: "right",
      new_line: 13,
      body: "I am checking this exact range.",
      state: "draft"
    )

    get notes_path

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("unresolved_count" => 0, "handled_count" => 1)
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
    create_note
    PluginRecord.find_by!(name: "cognitive_review").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    get notes_path

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end
end
