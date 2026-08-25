require "rails_helper"
require "tmpdir"

RSpec.describe ChatSession do
  let(:repo) { Factories.repository }

  def captured_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      queries << payload[:sql].to_s
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  it "creates with valid attributes and token defaults" do
    session = described_class.create!(repository: repo, user: repo.user, title: "Plan the aqueduct")

    expect(session).to be_persisted
    expect(session.attached_repositories).to contain_exactly(repo)
    expect(session.repository).to eq(repo)
    expect(session.cumulative_input_tokens).to eq(0)
    expect(session.cumulative_output_tokens).to eq(0)
    expect(session.cumulative_cost).to eq(0)
  end

  it "uses preloaded repository attachments when resolving the primary repository" do
    described_class.create!(repository: repo, user: repo.user, title: "Plan the aqueduct")
    session = described_class.preload(repository_attachments: :attachable).find_by!(title: "Plan the aqueduct")

    queries = captured_sql { expect(session.repository).to eq(repo) }

    expect(queries.grep(/chat_attachments|repositories/i)).to be_empty
  end

  it "can exist without an attached repository" do
    session = described_class.new(user: repo.user)

    expect(session).to be_valid
  end

  it "allows a supported chat provider" do
    session = described_class.new(user: repo.user, chat_provider: "codex")

    expect(session).to be_valid
  end

  it "seeds blank chat providers from the user's effective chat provider" do
    repo.user.update!(agent_provider: "codex", chat_provider: nil)
    session = described_class.create!(user: repo.user, chat_provider: "")

    expect(session.chat_provider).to eq("codex")
  end

  it "rejects unknown chat providers" do
    session = described_class.new(user: repo.user, chat_provider: "oracle")

    expect(session).not_to be_valid
    expect(session.errors[:chat_provider]).to be_present
  end

  it "allows valid modes" do
    %w[planning coding local].each do |mode|
      session = described_class.new(user: repo.user, mode: mode)
      expect(session).to be_valid, "expected mode #{mode.inspect} to be valid"
    end
  end

  it "allows a nil mode" do
    session = described_class.new(user: repo.user, mode: nil)

    expect(session).to be_valid
  end

  it "normalizes blank modes to nil" do
    session = described_class.create!(user: repo.user, mode: "")

    expect(session.mode).to be_nil
  end

  it "rejects unknown modes" do
    session = described_class.new(user: repo.user, mode: "turbo")

    expect(session).not_to be_valid
    expect(session.errors[:mode]).to be_present
  end

  it "allows valid daemon states" do
    %w[connected disconnected].each do |state|
      session = described_class.new(user: repo.user, local_daemon_state: state)
      expect(session).to be_valid, "expected local_daemon_state #{state.inspect} to be valid"
    end
  end

  it "allows nil daemon state" do
    session = described_class.new(user: repo.user, local_daemon_state: nil)

    expect(session).to be_valid
  end

  it "rejects unknown daemon states" do
    session = described_class.new(user: repo.user, local_daemon_state: "charging")

    expect(session).not_to be_valid
    expect(session.errors[:local_daemon_state]).to be_present
  end


  it "resolves persisted chat provider from the session only" do
    inherited = described_class.new(user: Factories.user(agent_provider: "codex"))
    user_override = described_class.new(user: Factories.user(agent_provider: "codex", chat_provider: "claude"))
    session_override = described_class.new(user: Factories.user(agent_provider: "claude"), chat_provider: "codex")

    expect(inherited.effective_chat_provider).to eq("claude")
    expect(user_override.effective_chat_provider).to eq("claude")
    expect(session_override.effective_chat_provider).to eq("codex")
  end

  it "pins a blank chat provider to the current effective provider" do
    user = Factories.user(agent_provider: "codex", chat_provider: "claude")
    session = described_class.new(user: user)
    session.chat_provider = nil

    expect {
      session.pin_chat_provider!
    }.to change(session, :chat_provider).from(nil).to("claude")

    user.update!(chat_provider: "codex")
    expect(session.effective_chat_provider).to eq("claude")
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

  it "records very large provider token counts" do
    session = described_class.create!(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: 2_147_483_000,
      cumulative_output_tokens: 2_147_483_000
    )
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "Done",
      session_id: "codex-session",
      input_tokens: 10_000,
      output_tokens: 20_000
    )

    session.record_turn_usage!(result)

    expect(session.reload.cumulative_input_tokens).to eq(2_147_493_000)
    expect(session.cumulative_output_tokens).to eq(2_147_503_000)
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

  it "excludes bookmarks on soft-deleted messages" do
    session = described_class.create!(repository: repo, user: repo.user)
    kept = session.messages.create!(role: "assistant", content: { "text" => "Kept" })
    cleared = session.messages.create!(role: "assistant", content: { "text" => "Cleared" })

    kept_bookmark = kept.bookmarks.create!(label: "Kept topic", kind: "topic")
    cleared.bookmarks.create!(label: "Cleared topic", kind: "topic")
    cleared.soft_delete_by!(repo.user)

    expect(session.bookmarks).to eq([ kept_bookmark ])
  end

  it "reports a turn in flight until a non-user response follows the latest user message" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect(session).not_to be_turn_in_flight

    user_message = session.messages.create!(role: "user", content: { "text" => "Ave" })
    expect(session).to be_turn_in_flight
    expect(session.last_message_at.to_i).to eq(user_message.created_at.to_i)

    assistant_message = session.messages.create!(role: "assistant", content: { "text" => "Salve" })
    expect(session).not_to be_turn_in_flight
    expect(session.last_message_at.to_i).to eq(assistant_message.created_at.to_i)
  end

  it "does not report a turn in flight for a user message that skips the turn trigger" do
    session = described_class.create!(repository: repo, user: repo.user)

    session.messages.create!(role: "user", content: { "text" => "Ave" }, skip_turn_trigger: true)

    expect(session).not_to be_turn_in_flight
  end

  it "reports whether an agent process is running in its workspace" do
    session = described_class.create!(repository: repo, user: repo.user)
    expect(session).not_to be_agent_busy

    pidless = SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: session.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )
    expect(session).not_to be_agent_busy

    pidless.update!(pid: 1234)

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

  describe "#rename!" do
    it "clears the failed-generation fallback flag so ChatTitleJob does not overwrite an explicit rename" do
      session = described_class.create!(repository: repo, user: repo.user, title: repo.name, title_auto_fallback: true)

      session.rename!("Calendar planning")

      expect(session.reload.title).to eq("Calendar planning")
      expect(session.title_auto_fallback).to eq(false)
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
            effective_chat_provider: "claude",
            effective_chat_provider_label: "Claude Code",
            provider_availability: nil,
            coding_checkout_uncommitted: false,
            title: "Updated chat",
            title_pending: false,
            system_kind: nil,
            pinned_context: nil,
            mode: nil,
            local_daemon_state: nil,
            local_daemon_repo: nil,
            local_daemon_branch: nil,
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
          queued_messages: [],
          scratchpad_items: []
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

  describe "soft deletion" do
    let(:actor) { Factories.user }

    around do |example|
      original = ENV["SYRUS_DATA_ROOT"]
      Dir.mktmpdir("syrus-chat-session-soft-delete") do |dir|
        ENV["SYRUS_DATA_ROOT"] = dir
        example.run
      ensure
        ENV["SYRUS_DATA_ROOT"] = original
      end
    end

    describe ".active and .deleted scopes" do
      it "returns only non-deleted sessions from .active and only deleted sessions from .deleted" do
        active_session = described_class.create!(repository: repo, user: repo.user)
        deleted_session = described_class.create!(repository: repo, user: repo.user)
        deleted_session.soft_delete_by!(actor)

        expect(described_class.active).to include(active_session)
        expect(described_class.active).not_to include(deleted_session)
        expect(described_class.deleted).to include(deleted_session)
        expect(described_class.deleted).not_to include(active_session)
      end
    end

    describe "#soft_delete_by!" do
      it "sets deleted_at and deleted_by_user for a User actor" do
        session = described_class.create!(repository: repo, user: repo.user)

        session.soft_delete_by!(actor)

        expect(session).to be_deleted
        expect(session.deleted_at).to be_present
        expect(session.deleted_by_user).to eq(actor)
      end

      it "sets deleted_at without deleted_by_user for a non-User actor" do
        session = described_class.create!(repository: repo, user: repo.user)

        session.soft_delete_by!(session)

        expect(session).to be_deleted
        expect(session.deleted_by_user).to be_nil
      end

      it "does not destroy the row or its dependent records" do
        session = described_class.create!(repository: repo, user: repo.user)
        proposal = session.proposals.create!(slug: "upstream-work", title: "Upstream work", body: "First.")

        session.soft_delete_by!(actor)

        expect(described_class.exists?(session.id)).to be(true)
        expect(ChatProposal.exists?(proposal.id)).to be(true)
      end

      it "enqueues the workspace/search cleanup job post-commit, same as a hard destroy" do
        session = described_class.create!(repository: repo, user: repo.user)
        session.update_columns(workspace_path: "/tmp/syrus-data/chat-workspaces/#{session.id}")

        expect { session.soft_delete_by!(actor) }
          .to have_enqueued_job(ChatSessionCleanupJob)
          .with(session.id, "/tmp/syrus-data/chat-workspaces/#{session.id}")
          .on_queue("chat")
      end

      it "does not re-enqueue the cleanup job on further unrelated updates" do
        session = described_class.create!(repository: repo, user: repo.user)
        session.soft_delete_by!(actor)

        expect { session.update!(pinned: true) }.not_to have_enqueued_job(ChatSessionCleanupJob)
      end
    end

    describe "#deleted?" do
      it "is false for a session with no deleted_at" do
        session = described_class.create!(repository: repo, user: repo.user)

        expect(session.deleted?).to be false
      end

      it "is true once soft-deleted" do
        session = described_class.create!(repository: repo, user: repo.user)
        session.soft_delete_by!(actor)

        expect(session.deleted?).to be true
      end
    end
  end

  describe "mode" do
    it "defaults to nil when no mode is given" do
      session = described_class.create!(user: repo.user)

      expect(session.mode).to be_nil
    end

    it "accepts planning mode" do
      session = described_class.new(user: repo.user, mode: "planning")

      expect(session).to be_valid
      expect(session).to be_planning
      expect(session).not_to be_coding
    end

    it "accepts coding mode" do
      session = described_class.new(user: repo.user, mode: "coding")

      expect(session).to be_valid
      expect(session).to be_coding
    end

    it "rejects unknown modes with a validation error" do
      session = described_class.new(user: repo.user, mode: "autopilot")

      expect(session).not_to be_valid
      expect(session.errors[:mode]).to be_present
    end
  end

  describe "system_kind" do
    it "accepts supervisor as a durable chat identity separate from mode" do
      session = described_class.new(user: repo.user, system_kind: "supervisor", mode: "planning", title: "Supervisor", pinned: true)

      expect(session).to be_valid
      expect(session).to be_system_kind_supervisor
      expect(session).to be_planning
    end

    it "rejects unknown system kinds" do
      session = described_class.new(user: repo.user, system_kind: "ops")

      expect(session).not_to be_valid
      expect(session.errors[:system_kind]).to be_present
    end

    it "enforces one supervisor chat per user at the database level" do
      now = Time.current
      attrs = {
        user_id: repo.user.id,
        system_kind: "supervisor",
        chat_provider: "claude",
        title: "Supervisor",
        pinned: true,
        artifacts: "{}",
        created_at: now,
        updated_at: now
      }
      described_class.insert_all!([ attrs ])

      expect { described_class.insert_all!([ attrs.merge(created_at: now + 1.second, updated_at: now + 1.second) ]) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows ordinary chats to keep nil system_kind for the same user" do
      expect {
        described_class.create!(user: repo.user)
        described_class.create!(user: repo.user)
      }.to change(described_class, :count).by(2)
    end

    it "prevents hiding, renaming, unpinning, or destroying a supervisor chat while enabled" do
      Feature.create!(slug: "admin_supervisor_chat", category: "Operations", name: "Admin supervisor chat", enabled: true)
      session = described_class.create!(user: repo.user, system_kind: "supervisor", title: "Supervisor", pinned: true)

      expect(session.update(title: "Renamed")).to be(false)
      expect(session.update(pinned: false)).to be(false)
      expect(session.update(hidden_at: Time.current)).to be(false)
      expect { session.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(described_class.exists?(session.id)).to be(true)
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

  describe "chat participants" do
    it "creates an owner participant when the session is created" do
      session = described_class.create!(user: repo.user)

      expect(session.chat_participants.count).to eq(1)
      expect(session.chat_participants.first.user).to eq(repo.user)
      expect(session.chat_participants.first.role).to eq("owner")
    end

    it "exposes participants through the through association" do
      session = described_class.create!(user: repo.user)
      other_user = Factories.user
      session.chat_participants.create!(user: other_user, role: "member")

      expect(session.participants).to contain_exactly(repo.user, other_user)
    end

    it "returns the owner user via the user association" do
      session = described_class.create!(user: repo.user)

      expect(session.user).to eq(repo.user)
    end
  end

  describe ".for_platform" do
    it "creates a new session for a user on an unknown platform" do
      user = repo.user

      session = described_class.for_platform(user: user, platform: "telegram")

      expect(session).to be_persisted
      expect(session.origin_platform).to eq("telegram")
      expect(session.trigger_policy).to eq("speak_when_spoken_to")
      expect(session.participants).to include(user)
    end

    it "finds the existing session on repeated calls for the same user and platform" do
      user = repo.user
      first = described_class.for_platform(user: user, platform: "telegram")

      second = described_class.for_platform(user: user, platform: "telegram")

      expect(second.id).to eq(first.id)
    end

    it "creates separate sessions for different platforms" do
      user = repo.user
      telegram = described_class.for_platform(user: user, platform: "telegram")
      slack = described_class.for_platform(user: user, platform: "slack")

      expect(telegram.id).not_to eq(slack.id)
    end

    it "creates separate sessions for different users on the same platform" do
      other_user = Factories.user
      session1 = described_class.for_platform(user: repo.user, platform: "telegram")
      session2 = described_class.for_platform(user: other_user, platform: "telegram")

      expect(session1.id).not_to eq(session2.id)
    end
  end

  describe "trigger_policy" do
    it "defaults to speak_when_spoken_to" do
      session = described_class.create!(user: repo.user)

      expect(session.trigger_policy).to eq("speak_when_spoken_to")
    end

    it "rejects unknown trigger policies" do
      session = described_class.new(user: repo.user, trigger_policy: "proactive")

      expect(session).not_to be_valid
      expect(session.errors[:trigger_policy]).to be_present
    end
  end

  describe "conversation_kind" do
    it "defaults to direct" do
      session = described_class.create!(user: repo.user)

      expect(session.conversation_kind).to eq("direct")
      expect(session).to be_direct
    end

    it "accepts group" do
      session = described_class.create!(user: repo.user, conversation_kind: "group")

      expect(session.conversation_kind).to eq("group")
      expect(session).to be_group
    end

    it "rejects unknown conversation kinds" do
      session = described_class.new(user: repo.user, conversation_kind: "team")

      expect(session).not_to be_valid
      expect(session.errors[:conversation_kind]).to be_present
    end

    it "is immutable after creation" do
      session = described_class.create!(user: repo.user, conversation_kind: "direct")

      session.conversation_kind = "group"

      expect(session).not_to be_valid
      expect(session.errors[:conversation_kind]).to be_present
      expect { session.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(session.reload.conversation_kind).to eq("direct")
    end

    it "does not shadow ActiveRecord's GROUP BY query method with a `group` scope" do
      described_class.create!(user: repo.user, conversation_kind: "group")

      expect { described_class.group("chat_sessions.id").count }.not_to raise_error
    end
  end

  describe "#participants_payload" do
    it "returns id, name, and role for every participant" do
      session = described_class.create!(user: repo.user)
      other_user = Factories.user(first_name: "Cato", last_name: "Elder")
      session.chat_participants.create!(user: other_user, role: "member")

      expect(session.participants_payload).to contain_exactly(
        include(id: repo.user.id, role: "owner"),
        include(id: other_user.id, name: "Cato Elder", role: "member")
      )
    end
  end

  describe "#agent_addressed?" do
    it "matches a case-insensitive @syrus substring" do
      session = described_class.create!(user: repo.user)

      expect(session.agent_addressed?("hey @Syrus can you help?")).to be true
      expect(session.agent_addressed?("@SYRUS")).to be true
    end

    it "does not false-positive on unrelated text" do
      session = described_class.create!(user: repo.user)

      expect(session.agent_addressed?("syrus is great but no mention here")).to be false
      expect(session.agent_addressed?("")).to be false
      expect(session.agent_addressed?(nil)).to be false
    end
  end

  describe "#should_trigger_agent?" do
    it "always triggers with 0-1 human participants, mention or not" do
      session = described_class.create!(user: repo.user)

      expect(session.chat_participants.count).to eq(1)
      expect(session.should_trigger_agent?("no mention here")).to be true
      expect(session.should_trigger_agent?("@syrus hello")).to be true
    end

    it "requires a mention once a second human participant joins" do
      session = described_class.create!(user: repo.user, conversation_kind: "group")
      session.chat_participants.create!(user: Factories.user, role: "member")

      expect(session.chat_participants.count).to eq(2)
      expect(session.should_trigger_agent?("no mention here")).to be false
      expect(session.should_trigger_agent?("hey @syrus")).to be true
    end
  end

  describe "#broadcast_participants_update!" do
    it "broadcasts a participants payload to the current participant set by default" do
      session = described_class.create!(user: repo.user, conversation_kind: "group")
      other_user = Factories.user
      session.chat_participants.create!(user: other_user, role: "member")

      expect(AppEvents).to receive(:broadcast).with(hash_including(user: repo.user, resource: "chat", changed: [ "participants" ]))
      expect(AppEvents).to receive(:broadcast).with(hash_including(user: other_user, resource: "chat", changed: [ "participants" ]))

      session.broadcast_participants_update!
    end

    it "broadcasts to an explicit recipient list, including a just-removed participant" do
      session = described_class.create!(user: repo.user, conversation_kind: "group")
      removed_user = Factories.user

      expect(AppEvents).to receive(:broadcast).with(hash_including(user: repo.user))
      expect(AppEvents).to receive(:broadcast).with(hash_including(user: removed_user))

      session.broadcast_participants_update!(recipients: [ repo.user, removed_user ])
    end
  end

  describe "broadcasting to participants" do
    it "broadcasts header updates to all participants" do
      session = described_class.create!(user: repo.user)
      other_user = Factories.user
      session.chat_participants.create!(user: other_user, role: "member")

      expect(AppEvents).to receive(:broadcast).with(hash_including(user: repo.user))
      expect(AppEvents).to receive(:broadcast).with(hash_including(user: other_user))

      session.broadcast_app_header_update
    end

    it "broadcasts controls updates to all participants" do
      session = described_class.create!(user: repo.user)
      other_user = Factories.user
      session.chat_participants.create!(user: other_user, role: "member")

      expect(AppEvents).to receive(:broadcast).with(hash_including(user: repo.user))
      expect(AppEvents).to receive(:broadcast).with(hash_including(user: other_user))

      session.broadcast_app_controls_update
    end

    it "falls back to the session user if no participants exist" do
      session = described_class.create!(user: repo.user)
      session.chat_participants.destroy_all

      expect(AppEvents).to receive(:broadcast).with(hash_including(user: repo.user)).once

      session.broadcast_app_header_update
    end
  end
end
