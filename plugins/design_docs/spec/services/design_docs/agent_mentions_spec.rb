require "rails_helper"

RSpec.describe "Design Docs @syrus agent mentions" do
  include ActiveJob::TestHelper

  let(:owner) { Factories.user(email_address: "owner@example.com", agent_provider: "codex", codex_api_key: "sk-test") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com", agent_provider: "codex", codex_api_key: "sk-test") }
  let(:outsider) { Factories.user(email_address: "outsider@example.com", agent_provider: "codex", codex_api_key: "sk-test") }

  def create_design_doc(markdown: "Alpha beta gamma", visibility: "private")
    doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Checkout design", markdown: markdown, visibility: visibility)
    version = doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    doc.update!(current_version: version)
    doc
  end

  def create_thread(doc, user: collaborator)
    doc.collaborators.create!(user: user, role: "editor", added_by_user: owner) unless user == owner
    DesignDocs::CreateComment.call(
      design_doc: doc,
      user: user,
      attributes: { body: "Needs evidence", start_offset: 6, end_offset: 10, selected_markdown: "beta" }
    ).thread
  end

  def result_fixture(final_text:, **overrides)
    AgentInvocation::Result.new(**{
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: final_text,
      session_id: "design-doc-session",
      transcript_jsonl: "{}\n"
    }.merge(overrides))
  end

  before do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    DesignDocs::AgentRunJob.agent_runner = nil
  end

  after do
    DesignDocs::AgentRunJob.agent_runner = nil
  end

  it "detects @syrus case-insensitively outside code blocks and quoted text" do
    expect(DesignDocs::AgentMentionDetector.mentioned?("Please ask @Syrus")).to be(true)
    expect(DesignDocs::AgentMentionDetector.mentioned?("> @syrus from pasted history")).to be(false)
    expect(DesignDocs::AgentMentionDetector.mentioned?("```rb\n@syrus\n```")).to be(false)
    expect(DesignDocs::AgentMentionDetector.mentioned?("`@syrus`")).to be(false)
    expect(DesignDocs::AgentMentionDetector.mentioned?("No mention")).to be(false)
  end

  it "enqueues one run for a new comment mention with full thread context" do
    doc = create_design_doc
    thread = create_thread(doc)

    expect {
      thread.comments.create!(author_kind: "user", author_user: collaborator, body: "@syrus suggest clearer wording")
    }.to change(DesignDocs::DesignDocAgentRun, :count).by(1)
      .and have_enqueued_job(DesignDocs::AgentRunJob).on_queue("chat")

    run = DesignDocs::DesignDocAgentRun.last
    expect(run).to have_attributes(
      design_doc: doc,
      thread: thread,
      requested_by_user: collaborator,
      base_version: doc.current_version,
      status: "queued"
    )
    expect(run.context_snapshot.dig("design_doc", "doc_ref")).to eq(doc.display_id)
    expect(run.context_snapshot.dig("thread", "comments").map { |comment| comment.fetch("body") }).to include("Needs evidence", "@syrus suggest clearer wording")
  end

  it "enqueues for a reply mention and includes existing pending suggestions on the thread" do
    doc = create_design_doc
    thread = create_thread(doc)
    suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: { thread_id: thread.id, start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "release", change_summary: "Clarify term" }
    ).suggestion

    thread.comments.create!(author_kind: "user", author_user: owner, body: "@syrus is this right?")

    run = DesignDocs::DesignDocAgentRun.last
    expect(run.context_snapshot.dig("pending_suggestions", 0, "id")).to eq(suggestion.id)
    expect(run.context_snapshot.dig("thread", "comments").map { |comment| comment.fetch("body") }).to include("@syrus is this right?")
  end

  it "does not duplicate runs for duplicate saves or while a thread run is active" do
    doc = create_design_doc
    thread = create_thread(doc)
    comment = thread.comments.create!(author_kind: "user", author_user: collaborator, body: "@syrus first")
    first_run = DesignDocs::DesignDocAgentRun.last

    expect {
      DesignDocs::RequestAgentRun.call(comment: comment, user: collaborator)
      thread.comments.create!(author_kind: "user", author_user: owner, body: "@syrus second")
    }.not_to change(DesignDocs::DesignDocAgentRun, :count)

    expect(thread.agent_runs.active).to contain_exactly(first_run)
  end

  it "triggers on edits that newly introduce @syrus" do
    doc = create_design_doc
    thread = create_thread(doc)
    comment = thread.comments.create!(author_kind: "user", author_user: collaborator, body: "Please review")

    expect {
      comment.update!(body: "Please review, @syrus")
    }.to change(DesignDocs::DesignDocAgentRun, :count).by(1)

    expect {
      comment.update!(body: "Please review, @syrus again")
    }.not_to change(DesignDocs::DesignDocAgentRun, :count)
  end

  it "does not trigger for users who cannot comment on the doc" do
    doc = create_design_doc
    thread = create_thread(doc, user: owner)

    expect {
      thread.comments.create!(author_kind: "user", author_user: outsider, body: "@syrus please help")
    }.not_to change(DesignDocs::DesignDocAgentRun, :count)
  end

  it "creates a pending suggestion with run and triggering comment provenance" do
    doc = create_design_doc
    thread = create_thread(doc)
    trigger = thread.comments.create!(author_kind: "user", author_user: collaborator, body: "@syrus suggest clearer wording")
    run = DesignDocs::DesignDocAgentRun.last
    DesignDocs::AgentRunJob.agent_runner = ->(**_) {
      result_fixture(final_text: {
        action: "suggestion",
        summary: "Suggested clearer wording.",
        suggestion: {
          start_offset: 6,
          end_offset: 10,
          original_markdown: "beta",
          proposed_markdown: "release",
          change_summary: "Clarify the wording"
        }
      }.to_json)
    }

    perform_enqueued_jobs(only: DesignDocs::AgentRunJob)

    suggestion = DesignDocs::DesignDocSuggestion.last
    expect(run.reload).to have_attributes(status: "succeeded", result_summary: "Suggested clearer wording.")
    expect(suggestion).to have_attributes(thread: thread, suggested_by_kind: "agent", agent_run: run)
    expect(suggestion.provenance).to include(
      "design_doc_agent_run_id" => run.id,
      "triggering_comment_id" => trigger.id
    )
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Alpha beta gamma")
  end

  it "posts implementation requests as agent-authored redirect comments" do
    doc = create_design_doc
    thread = create_thread(doc)
    thread.comments.create!(author_kind: "user", author_user: collaborator, body: "@syrus implement this in the repo")
    run = DesignDocs::DesignDocAgentRun.last
    DesignDocs::AgentRunJob.agent_runner = ->(**_) {
      result_fixture(final_text: {
        action: "comment",
        summary: "Redirected to chat proposal flow.",
        comment_body: "This should be routed through chat as a Job/Epic proposal."
      }.to_json)
    }

    perform_enqueued_jobs(only: DesignDocs::AgentRunJob)

    comment = thread.comments.order(:created_at, :id).last
    expect(comment).to have_attributes(author_kind: "agent", author_user: nil, agent_run: run)
    expect(comment.body).to include("Job/Epic proposal")
  end
end
