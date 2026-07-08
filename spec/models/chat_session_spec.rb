require "rails_helper"
require "tmpdir"

RSpec.describe ChatSession do
  let(:repo) { Factories.repository }

  it "creates with valid attributes and token defaults" do
    session = described_class.create!(repository: repo, user: repo.user, title: "Plan the aqueduct")

    expect(session).to be_persisted
    expect(session.attached_repositories).to contain_exactly(repo)
    expect(session.repository).to eq(repo)
    expect(session.cumulative_input_tokens).to eq(0)
    expect(session.cumulative_output_tokens).to eq(0)
    expect(session.cumulative_cost).to eq(0)
  end

  it "can exist without an attached repository" do
    session = described_class.new(user: repo.user)

    expect(session).to be_valid
  end

  it "allows a nullable supported chat provider" do
    session = described_class.new(user: repo.user, chat_provider: "codex")

    expect(session).to be_valid
  end

  it "normalizes blank chat providers to nil" do
    session = described_class.create!(user: repo.user, chat_provider: "")

    expect(session.chat_provider).to be_nil
  end

  it "rejects unknown chat providers" do
    session = described_class.new(user: repo.user, chat_provider: "oracle")

    expect(session).not_to be_valid
    expect(session.errors[:chat_provider]).to be_present
  end

  it "resolves chat provider from the session, user chat provider, then user agent provider" do
    inherited = described_class.new(user: Factories.user(agent_provider: "codex"))
    user_override = described_class.new(user: Factories.user(agent_provider: "codex", chat_provider: "claude"))
    session_override = described_class.new(user: Factories.user(agent_provider: "claude"), chat_provider: "codex")

    expect(inherited.effective_chat_provider).to eq("codex")
    expect(user_override.effective_chat_provider).to eq("claude")
    expect(session_override.effective_chat_provider).to eq("codex")
  end

  it "requires a user" do
    session = described_class.new

    expect(session).not_to be_valid
    expect(session.errors[:user]).to be_present
  end

  it "rejects negative usage totals" do
    session = described_class.new(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: -1,
      cumulative_output_tokens: -1,
      cumulative_cost_usd: -0.01
    )

    expect(session).not_to be_valid
    expect(session.errors[:cumulative_input_tokens]).to be_present
    expect(session.errors[:cumulative_output_tokens]).to be_present
    expect(session.errors[:cumulative_cost_usd]).to be_present
  end

  it "reports the cumulative cost supplied by Claude CLI" do
    session = described_class.new(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: 12_400,
      cumulative_output_tokens: 3_200
    )

    expect(session.cumulative_cost).to eq(0)
  end

  it "records turn usage from Claude CLI results without deriving price from tokens" do
    session = described_class.create!(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: 12_400,
      cumulative_output_tokens: 3_200,
      cumulative_cost_usd: 0.01
    )
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "Done",
      session_id: "claude-session",
      cost_usd: 0.004321,
      input_tokens: 100,
      output_tokens: 25
    )

    session.record_turn_usage!(result)

    expect(session.reload.cumulative_input_tokens).to eq(12_500)
    expect(session.cumulative_output_tokens).to eq(3_225)
    expect(session.cumulative_cost).to eq(BigDecimal("0.014321"))
  end

  it "records zero usage fields without changing existing totals" do
    session = described_class.create!(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: 12,
      cumulative_output_tokens: 34,
      cumulative_cost_usd: 0.05
    )
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "Done",
      session_id: "claude-session",
      cost_usd: 0,
      input_tokens: 0,
      output_tokens: 0
    )

    session.record_turn_usage!(result)

    expect(session.reload.cumulative_input_tokens).to eq(12)
    expect(session.cumulative_output_tokens).to eq(34)
    expect(session.cumulative_cost).to eq(BigDecimal("0.05"))
  end

  it "ignores nil usage fields" do
    session = described_class.create!(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: 12,
      cumulative_output_tokens: 34,
      cumulative_cost_usd: 0.05
    )
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "Done",
      session_id: "claude-session",
      cost_usd: nil,
      input_tokens: nil,
      output_tokens: nil
    )

    session.record_turn_usage!(result)

    expect(session.reload.cumulative_input_tokens).to eq(12)
    expect(session.cumulative_output_tokens).to eq(34)
    expect(session.cumulative_cost).to eq(BigDecimal("0.05"))
  end

  it "destroys messages with the session" do
    session = described_class.create!(repository: repo, user: repo.user)
    message = session.messages.create!(role: "user", content: { "text" => "Ave" })

    expect { session.destroy }.to change { ChatMessage.where(id: message.id).count }.by(-1)
  end

  it "lists bookmarks through messages in message chronology" do
    session = described_class.create!(repository: repo, user: repo.user)
    later = session.messages.create!(
      role: "assistant",
      content: { "text" => "Second" },
      created_at: 1.minute.from_now
    )
    earlier = session.messages.create!(
      role: "assistant",
      content: { "text" => "First" },
      created_at: 1.minute.ago
    )
    middle = session.messages.create!(
      role: "assistant",
      content: { "text" => "Middle" },
      created_at: Time.current
    )

    later_bookmark = later.bookmarks.create!(label: "Second topic", kind: "topic")
    earlier_bookmark = earlier.bookmarks.create!(label: "First topic", kind: "manual")
    middle_bookmark = middle.bookmarks.create!(label: "Epic launch", kind: "epic_origin")

    expect(session.bookmarks).to eq([ earlier_bookmark, middle_bookmark, later_bookmark ])
  end

  it "reports a turn in flight until a non-user response follows the latest user message" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect(session).not_to be_turn_in_flight

    session.messages.create!(role: "user", content: { "text" => "Ave" })
    expect(session).to be_turn_in_flight

    session.messages.create!(role: "assistant", content: { "text" => "Salve" })
    expect(session).not_to be_turn_in_flight
  end

  it "reports whether an agent process is running in its workspace" do
    session = described_class.create!(repository: repo, user: repo.user)
    expect(session).not_to be_agent_busy

    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: session.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )

    expect(session).to be_agent_busy
  end

  it "is destroyed with its repository" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect { repo.destroy }.to change { described_class.where(id: session.id).count }.by(-1)
  end

  it "is visible from the owning user" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect(repo.user.chat_sessions).to include(session)
  end

  describe ".fallback_title_for" do
    it "uses the repository name as the fallback title" do
      expect(described_class.fallback_title_for(repo)).to eq(repo.name)
    end
  end

  describe "#title_pending?" do
    it "is pending when a user message exists before the generated title is stored" do
      session = described_class.create!(repository: repo, user: repo.user, title: nil)
      session.messages.create!(role: "user", content: { "text" => "Build a calendar" })

      expect(session).to be_title_pending
    end

    it "is not pending once a title is stored" do
      session = described_class.create!(repository: repo, user: repo.user, title: "Calendar")
      session.messages.create!(role: "user", content: { "text" => "Build a calendar" })

      expect(session).not_to be_title_pending
    end
  end

  describe "React app events" do
    it "does not broadcast a header update for the initial repository attachment" do
      expect(AppEvents).not_to receive(:broadcast)

      described_class.create!(repository: repo, user: repo.user)
    end

    it "emits a header update payload for cached chat metadata" do
      stopped_at = Time.zone.parse("2026-05-30 12:00:00 UTC")
      session = described_class.create!(
        repository: repo,
        user: repo.user,
        title: "Updated chat",
        stop_requested_at: stopped_at,
        cumulative_input_tokens: 1500,
        cumulative_output_tokens: 250,
        cumulative_cost_usd: 0.125
      )
      expect(AppEvents).to receive(:broadcast).with(
        user: repo.user,
        type: "updated",
        resource: "chat",
        id: session.id,
        changed: [ "header" ],
        payload: {
          action: "update_header",
          chat: {
            chat_provider: "claude",
            title: "Updated chat",
            title_pending: false,
            pinned_context: nil,
            repository: {
              id: repo.id,
              slug: repo.slug
            },
            stop_requested_at: stopped_at.iso8601,
            cumulative_input_tokens: 1500,
            cumulative_output_tokens: 250,
            cumulative_cost_usd: 0.125
          }
        }
      )

      session.broadcast_header
    end

    it "emits a controls update payload when requested outside message-tail broadcasts" do
      stopped_at = Time.zone.parse("2026-05-30 12:00:00 UTC")
      session = described_class.create!(repository: repo, user: repo.user, stop_requested_at: stopped_at)
      expect(AppEvents).to receive(:broadcast).with(
        user: repo.user,
        type: "updated",
        resource: "chat",
        id: session.id,
        changed: [ "controls" ],
        payload: {
          action: "update_controls",
          turn_in_flight: false,
          agent_busy: false,
          switching_provider: false,
          stop_requested_at: stopped_at.iso8601,
          queued_messages: []
        }
      )

      session.broadcast_controls
    end

    it "can skip the controls app event when a message-tail event already carries the same state" do
      session = described_class.create!(repository: repo, user: repo.user)
      expect(AppEvents).not_to receive(:broadcast)

      session.broadcast_controls(app_event: false)
    end
  end

  describe "#attached_documents_in_scope" do
    it "returns repository documents reachable through repository, job, and direct document attachments" do
      user = repo.user
      other_repo = Factories.repository(user: user)
      unrelated_repo = Factories.repository(user: user)
      repo_document = repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Repo notes",
        google_docs_url: "https://docs.google.com/document/d/repo/edit"
      )
      job_document = other_repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Job notes",
        google_docs_url: "https://docs.google.com/document/d/job/edit"
      )
      direct_document = unrelated_repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Direct notes",
        google_docs_url: "https://docs.google.com/document/d/direct/edit"
      )
      unrelated_repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Out of scope",
        google_docs_url: "https://docs.google.com/document/d/out/edit"
      )
      job = Factories.job_record(user: user, repository: other_repo)
      session = described_class.create!(user: user, repository: repo)
      session.chat_attachments.create!(attachable: job)
      session.chat_attachments.create!(attachable: direct_document)

      expect(session.attached_documents_in_scope).to contain_exactly(repo_document, job_document, direct_document)
    end
  end

  describe "suggested next step" do
    let(:session) { described_class.create!(repository: repo, user: repo.user) }

    it "stores a trimmed suggestion and broadcasts a suggestion event" do
      events = []
      allow(AppEvents).to receive(:broadcast) { |**kwargs| events << kwargs }

      stored = session.record_suggested_next_step!("  Create an Epic from these findings  ")

      expect(stored).to eq("Create an Epic from these findings")
      expect(session.reload.suggested_next_step).to eq("Create an Epic from these findings")
      suggestion_event = events.find { |event| event[:changed] == [ "suggestion" ] }
      expect(suggestion_event[:payload]).to eq(
        action: "update_suggestion",
        suggested_next_step: "Create an Epic from these findings"
      )
    end

    it "clamps stored suggestions to the byte limit with safe_byteslice" do
      session.record_suggested_next_step!("ü" * 300)

      stored = session.reload.suggested_next_step
      expect(stored.bytesize).to be <= ChatSession::SUGGESTED_NEXT_STEP_MAX_BYTES
      expect(stored).to eq("ü" * 100)
      expect(stored).to be_valid_encoding
    end

    it "returns nil and stores nothing for blank suggestions" do
      session
      expect(AppEvents).not_to receive(:broadcast)

      expect(session.record_suggested_next_step!("   ")).to be_nil
      expect(session.reload.suggested_next_step).to be_nil
    end

    it "clears a stored suggestion and broadcasts the cleared value" do
      session.update!(suggested_next_step: "Ship it")
      events = []
      allow(AppEvents).to receive(:broadcast) { |**kwargs| events << kwargs }

      session.clear_suggested_next_step!

      expect(session.reload.suggested_next_step).to be_nil
      suggestion_event = events.find { |event| event[:changed] == [ "suggestion" ] }
      expect(suggestion_event[:payload]).to eq(
        action: "update_suggestion",
        suggested_next_step: nil
      )
    end

    it "does not broadcast when clearing an already-empty suggestion" do
      session
      expect(AppEvents).not_to receive(:broadcast)

      session.clear_suggested_next_step!
    end
  end

  describe "#destroy" do
    # ChatSessionCleanupJob derives filesystem paths from
    # SYRUS_DATA_ROOT (default ~/.syrus). Pin it to a throwaway tmpdir
    # so performing the job in specs can never touch a real data root.
    around do |example|
      original = ENV["SYRUS_DATA_ROOT"]
      Dir.mktmpdir("syrus-chat-session-destroy") do |dir|
        ENV["SYRUS_DATA_ROOT"] = dir
        example.run
      ensure
        ENV["SYRUS_DATA_ROOT"] = original
      end
    end

    it "purges the chat's search-index rows via the post-commit cleanup job" do
      prepare_search_tables
      session = described_class.create!(repository: repo, user: repo.user)
      message = session.messages.create!(role: "user", content: { "text" => "Aqueduct feasibility" })
      ChatMessageSearchIndex.insert(message)
      expect(ChatMessageSearchIndex.search("aqueduct", user_id: repo.user.id)).not_to be_empty
      id = session.id

      session.destroy!

      # The purge is deliberately NOT part of the destroy transaction —
      # it runs post-commit on the worker so a rollback can't leave the
      # index half-purged.
      expect(ChatMessageSearchIndex.search("aqueduct", user_id: repo.user.id)).not_to be_empty

      ChatSessionCleanupJob.perform_now(id, nil)

      expect(ChatMessageSearchIndex.search("aqueduct", user_id: repo.user.id)).to be_empty
    end

    it "enqueues the cleanup job post-commit with the chat id and recorded workspace path" do
      session = described_class.create!(repository: repo, user: repo.user)
      session.update_columns(workspace_path: "/tmp/syrus-data/chat-workspaces/#{session.id}")
      id = session.id

      expect { session.destroy! }
        .to have_enqueued_job(ChatSessionCleanupJob)
        .with(id, "/tmp/syrus-data/chat-workspaces/#{id}")
        .on_queue("chat")
    end

    it "survives destroy when the search schema is absent" do
      SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
      SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
      session = described_class.create!(repository: repo, user: repo.user)
      session.messages.create!(role: "user", content: { "text" => "No search here" })
      id = session.id

      expect { session.destroy! }.to change(described_class, :count).by(-1)
      expect { ChatSessionCleanupJob.perform_now(id, nil) }.not_to raise_error
    end

    it "removes pending JobDependency placeholders that reference its proposals before the proposals go" do
      session = described_class.create!(repository: repo, user: repo.user)
      proposal = session.proposals.create!(slug: "upstream-work", title: "Upstream work", body: "First.")
      dependent_job = Factories.job_record(user: repo.user, repository: repo)
      dependency = JobDependency.create!(job: dependent_job, unresolved_chat_proposal: proposal, source: "parsed")

      expect { session.destroy! }.not_to raise_error

      expect(JobDependency.exists?(dependency.id)).to be(false)
      expect(ChatProposal.exists?(proposal.id)).to be(false)
      expect(Job.exists?(dependent_job.id)).to be(true)
    end
  end

  describe "title length" do
    it "rejects titles longer than TITLE_MAX_LENGTH so no code path can overflow" do
      session = described_class.new(user: repo.user, title: "R" * (ChatSession::TITLE_MAX_LENGTH + 1))

      expect(session).not_to be_valid
      expect(session.errors[:title]).to be_present
    end

    it "accepts titles at exactly TITLE_MAX_LENGTH" do
      session = described_class.new(user: repo.user, title: "R" * ChatSession::TITLE_MAX_LENGTH)

      expect(session).to be_valid
    end
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(
        content,
        user_id UNINDEXED,
        chat_session_id UNINDEXED,
        chat_message_id UNINDEXED,
        role UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE TABLE chat_search_metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    SQL
  end
end
