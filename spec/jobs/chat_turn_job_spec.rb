require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe ChatTurnJob do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user) }
  let(:workspace_root) { Pathname.new(Dir.mktmpdir("syrus-chat-workspace")) }
  let(:workspace_path) { workspace_root.join("chat") }
  let(:user_message) { chat.messages.create!(role: "user", content: { text: "What is the plan?" }) }

  it "enqueues chat turns on the chat queue" do
    expect {
      described_class.perform_later(chat.id, user_message.id)
    }.to have_enqueued_job(described_class).with(chat.id, user_message.id).on_queue("chat")
  end

  before do
    ChatTurnJob.agent_runner = nil
    allow(ChatWorkspace).to receive(:path_for).and_call_original
    allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(workspace_path)
  end

  after do
    ChatTurnJob.agent_runner = nil
    FileUtils.rm_rf(workspace_root)
  end

  def enable_walkthroughs!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "video_walkthroughs") do |record|
      record.category = "Labs"
      record.name = "Walkthrough videos"
    end
    feature.update!(enabled: enabled)
  end

  def enable_coding_mode!(enabled: true)
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: enabled)
  end

  it "calls ensure_coding_checkout! instead of refreshing repository checkouts in coding mode" do
    enable_coding_mode!
    chat.update!(mode: "coding")
    ensure_called = false
    refresh_called = false
    allow(ChatWorkspace).to receive(:ensure_coding_checkout!) do
      ensure_called = true
    end
    allow(ChatWorkspace).to receive(:attach_repository!) do
      refresh_called = true
    end
    ChatTurnJob.agent_runner = ->(**_) { result_fixture(session_id: "s1") }

    described_class.perform_now(chat.id, user_message.id)

    expect(ensure_called).to eq(true)
    expect(refresh_called).to eq(false)
  end

  it "calls refresh for attached repositories in planning mode, not ensure_coding_checkout!" do
    ensure_called = false
    allow(ChatWorkspace).to receive(:ensure_coding_checkout!) { ensure_called = true }
    FileUtils.mkdir_p(ChatWorkspace.repo_path_for(chat, repository).join(".git"))
    allow(ChatWorkspace).to receive(:attach_repository!)
    ChatTurnJob.agent_runner = ->(**_) { result_fixture(session_id: "s1") }

    described_class.perform_now(chat.id, user_message.id)

    expect(ensure_called).to eq(false)
  end

  it "logs a warning and continues when ensure_coding_checkout! fails in coding mode" do
    enable_coding_mode!
    chat.update!(mode: "coding")
    allow(ChatWorkspace).to receive(:ensure_coding_checkout!).and_raise(StandardError, "clone failed")
    allow(Rails.logger).to receive(:warn)
    ran_agent = false
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      ran_agent = true
      result_fixture(session_id: "s1")
    }

    expect { described_class.perform_now(chat.id, user_message.id) }.not_to raise_error

    expect(ran_agent).to eq(true)
    expect(Rails.logger).to have_received(:warn).with(
      /coding checkout setup failed for chat ##{chat.id}: StandardError: clone failed/
    )
    expect(received[:prompt]).to include("Checkout setup warning")
    expect(received[:prompt]).to include("StandardError: clone failed")
  end

  it "updates coding_checkout_uncommitted after the turn when there are uncommitted changes" do
    enable_coding_mode!
    chat.update!(mode: "coding", coding_checkout_branch: "syrus-chat-#{chat.id}")
    path = ChatWorkspace.repo_path_for(chat, repository)
    allow(ChatWorkspace).to receive(:ensure_coding_checkout!)
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(path)
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(true)
    allow(AppEvents).to receive(:broadcast)
    ChatTurnJob.agent_runner = ->(**_) { result_fixture(session_id: "s1") }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.reload.coding_checkout_uncommitted).to eq(true)
  end

  it "does not update coding_checkout_uncommitted when state has not changed" do
    enable_coding_mode!
    chat.update!(mode: "coding", coding_checkout_branch: "syrus-chat-#{chat.id}", coding_checkout_uncommitted: false)
    path = ChatWorkspace.repo_path_for(chat, repository)
    allow(ChatWorkspace).to receive(:ensure_coding_checkout!)
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(path)
    allow(ChatWorkspace).to receive(:uncommitted_changes?).with(path).and_return(false)
    update_columns_called = false
    allow(chat).to receive(:update_columns).and_wrap_original do |original, **attrs|
      update_columns_called = true if attrs.key?(:coding_checkout_uncommitted)
      original.call(**attrs)
    end
    ChatTurnJob.agent_runner = ->(**_) { result_fixture(session_id: "s1") }

    described_class.perform_now(chat.id, user_message.id)

    expect(update_columns_called).to eq(false)
  end

  it "skips coding checkout state update when chat has no coding_checkout_branch" do
    enable_coding_mode!
    chat.update!(mode: "coding")
    allow(ChatWorkspace).to receive(:ensure_coding_checkout!)
    allow(ChatWorkspace).to receive(:uncommitted_changes?)
    ChatTurnJob.agent_runner = ->(**_) { result_fixture(session_id: "s1") }

    described_class.perform_now(chat.id, user_message.id)

    expect(ChatWorkspace).not_to have_received(:uncommitted_changes?)
  end

  it "does not inject the coding mode section when the feature flag is off (planning mode chat)" do
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:prompt]).not_to include("Coding Mode")
    expect(received[:prompt]).not_to include("complete_implement_step")
  end

  it "does not inject the coding mode section for a planning-mode chat even when the flag is on" do
    enable_coding_mode!
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:prompt]).not_to include("Coding Mode")
  end

  it "injects the coding mode section when the flag is on and the chat is in coding mode" do
    enable_coding_mode!
    chat.update!(mode: "coding")
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:prompt]).to include("Coding Mode")
    expect(received[:prompt]).to include("implement code")
    expect(received[:prompt]).to include("complete_implement_step")
    expect(received[:prompt]).to include("grader")
  end

  it "includes the workspace root and attached job context in the coding mode prompt" do
    enable_coding_mode!
    job = Factories.job_record(user: user, repository: repository, issue_title: "Add widget API",
                               branch_name: "syrus/direct-999")
    chat.chat_attachments.create!(attachable: job)
    chat.update!(
      mode: "coding",
      coding_checkout_branch: "main",
      coding_checkout_prepare_status: "queued"
    )

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:prompt]).to include(workspace_path.to_s)
    expect(received[:prompt]).to include("Checkout path: `#{workspace_path.join('repositories', 'acme', 'widgets')}`")
    expect(received[:prompt]).to include("Current branch: `main`")
    expect(received[:prompt]).to include("Current ref: `(unknown)`")
    expect(received[:prompt]).to include("Default branch: `main`")
    expect(received[:prompt]).to include("Prep status: queued")
    expect(received[:prompt]).to include("syrus/direct-999")
    expect(received[:prompt]).to include("Add widget API")
    expect(received[:prompt]).to include(job.id.to_s)
  end

  it "orients the agent to its walkthrough tools (not an analysis dump) for a walkthrough message" do
    enable_walkthroughs!
    walkthrough = ChatVideoWalkthrough.new(
      chat_session: chat, user: user, content_type: "video/mp4", byte_size: 10,
      duration_seconds: 101, title: "run", state: "analyzed",
      analysis: { "summary" => "s", "issues" => [], "open_questions" => [] }
    ).tap do |w|
      w.file.attach(io: StringIO.new("mp4"), filename: "w.mp4", content_type: "video/mp4")
      w.save!
    end
    message = chat.messages.create!(
      role: "user",
      content: { "text" => "watch save", "video_walkthrough_id" => walkthrough.id, "source" => "walkthrough" }
    )

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, message.id)

    expect(received[:prompt]).to include("get_walkthrough_analysis(walkthrough_id: #{walkthrough.id})")
    expect(received[:prompt]).to include("The operator's note with the video: watch save")
    expect(received[:prompt]).to include("propose an Epic")
    # The analysis itself is NOT dumped into the prompt — the agent pulls it.
    expect(received[:prompt]).not_to include("## Narration transcript")
  end

  it "treats a walkthrough message as a plain note when the labs flag is off" do
    enable_walkthroughs!(enabled: false)
    walkthrough = ChatVideoWalkthrough.new(
      chat_session: chat, user: user, content_type: "video/mp4", byte_size: 10,
      duration_seconds: 101, title: "run", state: "analyzed",
      analysis: { "summary" => "s", "issues" => [], "open_questions" => [] }
    ).tap do |w|
      w.file.attach(io: StringIO.new("mp4"), filename: "w.mp4", content_type: "video/mp4")
      w.save!
    end
    message = chat.messages.create!(
      role: "user",
      content: { "text" => "watch save", "video_walkthrough_id" => walkthrough.id, "source" => "walkthrough" }
    )

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, message.id)

    # No orientation toward tools the sidecar no longer advertises.
    expect(received[:prompt]).not_to include("get_walkthrough_analysis")
    expect(received[:prompt]).to include("watch save")
  end

  it "runs a first turn with the chat system prompt, MCP config, no max-turns, and captures output" do
    host_env = {
      "SYRUS_APP_HOST" => "syrus.example.test",
      "SYRUS_ALLOWED_HOSTS" => "syrus.example.test,syrus.internal.test",
      "SYRUS_ASSUME_SSL" => "true",
      "SYRUS_FORCE_SSL" => "true",
      "SYRUS_SQLITE" => "1",
      "SYRUS_DATA_ROOT" => "/home/rails/.syrus",
      "BUNDLE_PATH" => "/usr/local/bundle",
      "PATH" => "/opt/ruby/bin:/usr/local/bin:/usr/bin:/bin",
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "salt"
    }
    saved = ENV.to_h.slice(*host_env.keys)
    host_env.each { |key, value| ENV[key] = value }
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      config = JSON.parse(File.read(kwargs[:mcp_config]))
      essential = config.dig("mcpServers", "syrus-chat-sidecar")
      deferred = config.dig("mcpServers", "syrus-chat-deferred-sidecar")
      expect(essential["command"]).to eq(Rails.root.join("bin/syrus-chat-sidecar").to_s)
      expect(essential["args"]).to be_nil
      expect(essential.dig("env", "SYRUS_CHAT_SESSION_ID")).to eq(chat.id.to_s)
      expect(essential.dig("env", "SYRUS_CHAT_CURRENT_MESSAGE_ID")).to eq(user_message.id.to_s)
      expect(essential.dig("env", "SYRUS_CHAT_MCP_TOOL_TIER")).to eq("essential")
      expect(essential.dig("env", "SYRUS_CHAT_MCP_SERVER_NAME")).to eq("syrus-chat-sidecar")
      expect(essential["env"]).to include(host_env)
      expect(essential["env"]).to include("GEM_HOME" => "/usr/local/bundle", "GEM_PATH" => "/usr/local/bundle")
      expect(essential["alwaysLoad"]).to eq(true)
      expect(deferred["command"]).to eq(Rails.root.join("bin/syrus-chat-deferred-sidecar").to_s)
      expect(deferred["args"]).to be_nil
      expect(deferred.dig("env", "SYRUS_CHAT_SESSION_ID")).to eq(chat.id.to_s)
      expect(deferred.dig("env", "SYRUS_CHAT_CURRENT_MESSAGE_ID")).to eq(user_message.id.to_s)
      expect(deferred.dig("env", "SYRUS_CHAT_MCP_TOOL_TIER")).to eq("deferred")
      expect(deferred.dig("env", "SYRUS_CHAT_MCP_SERVER_NAME")).to eq("syrus-chat-deferred-sidecar")
      expect(deferred["alwaysLoad"]).to eq(false)

      kwargs[:log_sink].call("Here is the shape of it.", kind: "assistant_text")
      kwargs[:log_sink].call(
        "● propose_job(...)",
        kind: "tool_call",
        tool_name: "propose_job",
        tool_input: { "repo" => repository.slug, "title" => "T", "description" => "b" },
        tool_use_id: "toolu_abc123"
      )
      kwargs[:log_sink].call(
        "  Job drafted",
        kind: "tool_result",
        tool_name: "propose_job",
        tool_result_content: [ { "type" => "text", "text" => "Job drafted" } ],
        tool_result_error: false,
        tool_use_id: "toolu_abc123"
      )
      result_fixture(
        session_id: "chat-session-1",
        transcript_jsonl: "{\"type\":\"system\"}\n",
        cost_usd: 0.004321,
        input_tokens: 12,
        output_tokens: 5
      )
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:workspace_path]).to eq(workspace_path.to_s)
    expect(received[:prompt]).to include("You are Syrus Chat")
    expect(received[:prompt]).to include("What is the plan?")
    expect(received[:resume_session_id]).to be_nil
    expect(received[:max_turns]).to be_nil
    expect(received[:disallowed_tools]).to eq(%w[Write Edit MultiEdit NotebookEdit AskUserQuestion])
    expect(received[:image_paths]).to eq([])
    expect(received[:file_paths]).to eq([])

    expect(chat.messages.order(:created_at).pluck(:role)).to eq(
      [ "user", "assistant", "tool_use", "tool_result" ]
    )
    expect(chat.reload.cumulative_input_tokens).to eq(12)
    expect(chat.cumulative_output_tokens).to eq(5)
    expect(chat.cumulative_cost).to eq(BigDecimal("0.004321"))
    expect(chat.last_message_at).to be_present

    session = chat.claude_session
    expect(session).to have_attributes(
      resumable: chat,
      provider: "claude",
      session_id: "chat-session-1",
      transcript_jsonl: "{\"type\":\"system\"}\n",
      normalized_messages: []
    )
  ensure
    host_env&.keys&.each { |key| ENV.delete(key) }
    saved&.each { |key, value| ENV[key] = value }
  end

  it "includes attached Epic context in the first-turn prompt" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Stabilize the aqueduct",
      description: "Make the water arrive where the Romans insisted it should."
    )
    child = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_title: "Seal the northern arch",
      state: "queued"
    )
    chat.chat_attachments.create!(attachable: epic)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:prompt]).to include("Attached context:")
    expect(received[:prompt]).to include("#{epic.slug}: Stabilize the aqueduct")
    expect(received[:prompt]).to include("Make the water arrive")
    expect(received[:prompt]).to include("#{child.slug}: Seal the northern arch")
    expect(received[:prompt]).to include("Use `read_epic` with id #{epic.id}")
  end

  it "includes elaboration guidance on resumed turns after read_epic activation" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "PO backlog export",
      description: "Customers need CSV exports.",
      state: "backlog"
    )
    chat.messages.create!(role: "user", content: { "text" => "Inspect the Epic." })
    chat.messages.create!(
      role: "tool_result",
      tool_name: "read_epic",
      content: {
        "result" => [
          {
            "type" => "text",
            "text" => JSON.generate("epic" => { "id" => epic.id, "state" => "backlog" }, "child_jobs" => [])
          }
        ]
      }
    )
    chat.create_claude_session!(provider: "claude", session_id: "previous-session", transcript_jsonl: "{}\n")
    next_message = chat.messages.create!(role: "user", content: { "text" => "What should we ask next?" })

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "previous-session", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, next_message.id)

    expect(received[:resume_session_id]).to eq("previous-session")
    expect(received[:prompt]).to include("Developer elaboration mode: active for #{epic.slug}")
    expect(received[:prompt]).to include("## Developer Epic Elaboration Mode")
    expect(received[:prompt]).to include("Propose `update_epic` with a technically enriched description before proposing any Jobs")
    expect(received[:prompt]).to include("referencing the existing Epic with `epic_id: #{epic.id}`")
    expect(received[:prompt]).to include("What should we ask next?")
  end

  it "writes image attachments into the chat workspace and describes them in the prompt" do
    payload = "png-bytes"
    image_message = chat.messages.create!(
      role: "user",
      content: {
        text: "Inspect this image",
        attachments: [
          {
            name: "capture.png",
            mime_type: "image/png",
            data: Base64.strict_encode64(payload)
          }
        ]
      }
    )
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, image_message.id)

    expect(received[:image_paths].size).to eq(1)
    image_path = Pathname(received[:image_paths].first)
    expect(image_path.dirname).to eq(workspace_path.join("attachments"))
    expect(image_path.extname).to eq(".png")
    expect(File.binread(image_path)).to eq(payload)
    expect(received[:prompt]).to include("Attached image: capture.png")
    expect(received[:prompt]).to include("saved at #{image_path}")
    expect(received[:prompt]).not_to include("saved at attachments/#{image_path.basename}")
    expect(received[:prompt]).to include("Use the Read tool to inspect it")
    expect(received[:file_paths]).to eq([])
  end

  it "adds a prompt note for PDF attachments when Claude does not support --file" do
    allow(described_class).to receive(:claude_file_flag_supported?).and_return(false)
    pdf_message = chat.messages.create!(
      role: "user",
      content: {
        text: "Read this",
        attachments: [
          {
            name: "brief.pdf",
            mime_type: "application/pdf",
            data: Base64.strict_encode64("%PDF")
          }
        ]
      }
    )
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, pdf_message.id)

    expect(received[:image_paths]).to eq([])
    expect(received[:file_paths]).to eq([])
    expect(received[:prompt]).to include("[Attached PDF: brief.pdf]\nRead this")
    expect(Dir[workspace_path.join("attachments", "*.pdf").to_s].size).to eq(1)
  end

  it "can run a top-level chat before any repository is attached" do
    chat = ChatSession.create!(user: user)
    message = chat.messages.create!(role: "user", content: { text: "Inspect tkadauke/syrus" })
    top_level_path = workspace_root.join("top-level")
    allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(top_level_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(top_level_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, message.id)

    expect(received[:workspace_path]).to eq(top_level_path.to_s)
    expect(received[:prompt]).to include("Use `attach_repository(slug)`")
  end

  it "clears the stored next-step suggestion when a turn starts" do
    chat = ChatSession.create!(user: user, suggested_next_step: "Create an Epic from these findings")
    message = chat.messages.create!(role: "assistant", content: { text: "Proposal outcome" })
    top_level_path = workspace_root.join("suggestion")
    allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(top_level_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(top_level_path)

    suggestion_at_agent_start = :unset
    ChatTurnJob.agent_runner = ->(**_kwargs) {
      suggestion_at_agent_start = chat.reload.suggested_next_step
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, message.id)

    expect(suggestion_at_agent_start).to be_nil
    expect(chat.reload.suggested_next_step).to be_nil
  end

  it "passes a temporary git askpass helper to Claude for attached repositories and deletes it after success" do
    allow(GithubClient).to receive(:for)
      .with(repository: repository, user: user)
      .and_return(instance_double(GithubClient, access_token: "ghp-chat-token"))
    askpass_path = nil

    ChatTurnJob.agent_runner = ->(env:, **_) {
      askpass_path = env.fetch("GIT_ASKPASS")
      expect(env.fetch("GIT_TERMINAL_PROMPT")).to eq("0")
      expect(File.exist?(askpass_path)).to eq(true)
      expect(File.dirname(askpass_path)).to eq(Dir.tmpdir)
      expect(format("%o", File.stat(askpass_path).mode & 0o777)).to eq("700")
      expect(File.read(askpass_path)).to eq("#!/bin/sh\necho \"x-access-token:ghp-chat-token\"\n")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(askpass_path).to be_present
    expect(File.exist?(askpass_path)).to eq(false)
  end

  it "deletes the temporary git askpass helper when Claude raises" do
    allow(GithubClient).to receive(:for)
      .with(repository: repository, user: user)
      .and_return(instance_double(GithubClient, access_token: "ghp-chat-token"))
    askpass_path = nil

    ChatTurnJob.agent_runner = ->(env:, **_) {
      askpass_path = env.fetch("GIT_ASKPASS")
      expect(File.exist?(askpass_path)).to eq(true)
      raise "agent failed"
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(askpass_path).to be_present
    expect(File.exist?(askpass_path)).to eq(false)
  end

  it "does not pass git askpass to Claude when no repository is attached" do
    top_level_chat = ChatSession.create!(user: user)
    message = top_level_chat.messages.create!(role: "user", content: { text: "Inspect tkadauke/syrus" })
    top_level_path = workspace_root.join("top-level-no-askpass")
    allow(ChatWorkspace).to receive(:path_for).with(top_level_chat).and_return(top_level_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(top_level_chat).and_return(top_level_path)

    expect(GithubClient).not_to receive(:for)
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(top_level_chat.id, message.id)

    expect(received[:env]).to eq("GIT_TERMINAL_PROMPT" => "0")
  end

  it "refreshes already-cloned attached repository checkouts at turn start" do
    attached_repository = Factories.repository(user: user, owner: "acme", name: "toolbox", default_branch: "main")
    unmaterialized_repository = Factories.repository(user: user, owner: "acme", name: "not-cloned", default_branch: "main")
    chat.chat_attachments.create!(attachable: attached_repository)
    chat.chat_attachments.create!(attachable: unmaterialized_repository)
    FileUtils.mkdir_p(ChatWorkspace.repo_path_for(chat, repository).join(".git"))
    FileUtils.mkdir_p(ChatWorkspace.repo_path_for(chat, attached_repository).join(".git"))

    refreshed = []
    allow(ChatWorkspace).to receive(:attach_repository!) { |_chat, repo| refreshed << repo }
    ChatTurnJob.agent_runner = ->(**_) {
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(refreshed).to contain_exactly(repository, attached_repository)
  end

  it "logs and continues when an attached repository checkout refresh fails" do
    FileUtils.mkdir_p(ChatWorkspace.repo_path_for(chat, repository).join(".git"))
    allow(ChatWorkspace).to receive(:attach_repository!).with(chat, repository).and_raise(StandardError, "network unavailable")
    allow(Rails.logger).to receive(:warn)
    ran_agent = false
    ChatTurnJob.agent_runner = ->(**_) {
      ran_agent = true
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    expect {
      described_class.perform_now(chat.id, user_message.id)
    }.not_to raise_error

    expect(ran_agent).to eq(true)
    expect(Rails.logger).to have_received(:warn).with(
      /checkout refresh failed for chat ##{chat.id} #{repository.slug}: StandardError: network unavailable/
    )
  end

  it "preserves existing usage totals when invocation result usage fields are nil" do
    chat.update!(
      cumulative_input_tokens: 10,
      cumulative_output_tokens: 20,
      cumulative_cost_usd: 0.03
    )
    ChatTurnJob.agent_runner = ->(**_) {
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.reload.cumulative_input_tokens).to eq(10)
    expect(chat.cumulative_output_tokens).to eq(20)
    expect(chat.cumulative_cost).to eq(BigDecimal("0.03"))
  end

  it "broadcasts chat controls after the agent turn finishes" do
    message = user_message
    ChatTurnJob.agent_runner = ->(**_) {
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    allow(AppEvents).to receive(:broadcast)
    expect(AppEvents).to receive(:broadcast).with(
      user: chat.user,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "controls" ],
      payload: include(
        action: "update_controls",
        agent_busy: false,
        stop_requested_at: nil
      )
    )

    described_class.perform_now(chat.id, message.id)
  end

  it "clears stop requests and broadcasts controls when the turn fails before the agent starts" do
    message = user_message
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat) do
      chat.update!(stop_requested_at: Time.current)
      raise "workspace unavailable"
    end

    expect(AppEvents).to receive(:broadcast).with(
      user: chat.user,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "controls" ],
      payload: include(
        action: "update_controls",
        stop_requested_at: nil
      )
    )

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.stop_requested_at).to be_nil
  end

  it "clears mid-turn stop requests and broadcasts controls when the agent errors" do
    message = user_message
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Continue after failure" })
    ChatTurnJob.agent_runner = ->(**_) {
      chat.update!(stop_requested_at: Time.current)
      raise "agent failed"
    }

    allow(AppEvents).to receive(:broadcast)
    expect(AppEvents).to receive(:broadcast).with(
      user: chat.user,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "controls" ],
      payload: include(
        action: "update_controls",
        stop_requested_at: nil
      )
    )

    expect {
      described_class.perform_now(chat.id, message.id)
    }.to have_enqueued_job(described_class).with(chat.id, kind_of(Integer))

    expect(chat.reload.stop_requested_at).to be_nil
    expect(queued_message.reload.delivered_at).to be_present
    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ],
      [ "user", { "text" => "Continue after failure" } ]
    )
  end

  it "promotes the next queued message after the agent turn finishes" do
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Follow up on aqueducts" })
    ChatTurnJob.agent_runner = ->(**_) {
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    expect {
      described_class.perform_now(chat.id, user_message.id)
    }.to have_enqueued_job(described_class).with(chat.id, kind_of(Integer))

    delivered = chat.messages.order(:created_at, :id).last
    expect(delivered).to have_attributes(role: "user", content: { "text" => "Follow up on aqueducts" })
    expect(queued_message.reload.delivered_at).to be_present
    expect(chat.reload.queued_messages).to be_empty
  end

  it "promotes the next queued message after a provider failure finalizes the turn" do
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Recover from the failure" })
    ChatTurnJob.agent_runner = ->(**_) { raise "provider unavailable" }

    expect {
      described_class.perform_now(chat.id, user_message.id)
    }.to have_enqueued_job(described_class).with(chat.id, kind_of(Integer))

    expect(chat.reload.stop_requested_at).to be_nil
    expect(queued_message.reload.delivered_at).to be_present
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).to include(
      [ "system", a_hash_including("text" => "Agent turn failed: RuntimeError: provider unavailable") ],
      [ "user", { "text" => "Recover from the failure" } ]
    )
  end

  it "cancels without starting the agent when stop was requested before process start" do
    message = user_message
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Promote after cancellation" })
    chat.update!(stop_requested_at: Time.current)
    called = false
    ChatTurnJob.agent_runner = ->(**_) {
      called = true
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    expect {
      described_class.perform_now(chat.id, message.id)
    }.to have_enqueued_job(described_class).with(chat.id, kind_of(Integer))

    expect(called).to eq(false)
    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ],
      [ "user", { "text" => "Promote after cancellation" } ]
    )
    expect(queued_message.reload.delivered_at).to be_present
    expect(chat.reload.queued_messages).to be_empty
    expect(chat.stop_requested_at).to be_nil
  end

  it "promotes a queued follow-up after cancellation once the process is terminal" do
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Continue after stop" })
    ChatTurnJob.agent_runner = ->(workspace_path:, process_started:, stop_requested:, **_) {
      process = SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        workdir: workspace_path,
        hostname: "worker-1",
        started_at: Time.current
      )
      process_started.call(process)
      chat.update!(stop_requested_at: Time.current)

      expect(stop_requested.call).to eq(true)
      process.update!(finished_at: Time.current, outcome: "stopped")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    expect {
      described_class.perform_now(chat.id, user_message.id)
    }.to have_enqueued_job(described_class).with(chat.id, kind_of(Integer))

    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ],
      [ "user", { "text" => "Continue after stop" } ]
    )
    expect(queued_message.reload.delivered_at).to be_present
    expect(chat.reload.queued_messages).to be_empty
    expect(chat.stop_requested_at).to be_nil
  end

  it "does not promote a queued follow-up while the agent process is still live" do
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Wait for process exit" })
    ChatTurnJob.agent_runner = ->(workspace_path:, process_started:, stop_requested:, **_) {
      process = SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        workdir: workspace_path,
        hostname: "worker-1",
        started_at: Time.current
      )
      process_started.call(process)
      chat.update!(stop_requested_at: Time.current)

      expect(stop_requested.call).to eq(true)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    expect {
      described_class.perform_now(chat.id, user_message.id)
    }.not_to have_enqueued_job(described_class)

    expect(queued_message.reload.delivered_at).to be_nil
    expect(chat.reload.queued_messages).to contain_exactly(queued_message)
    expect(chat).to be_agent_busy
  end

  it "delivers one queued message under repeated promotion attempts" do
    chat.messages.create!(role: "assistant", content: { "text" => "Done" })
    first = chat.chat_queued_messages.create!(content: { "text" => "First queued" })
    second = chat.chat_queued_messages.create!(content: { "text" => "Second queued" })

    expect {
      2.times { ChatQueuedMessagePromoter.deliver_one_if_idle!(chat) }
    }.to have_enqueued_job(described_class).once

    expect(first.reload.delivered_at).to be_present
    expect(second.reload.delivered_at).to be_nil
    user_texts = chat.messages.where(role: "user").map { |message| message.content["text"] }
    expect(user_texts.count("First queued")).to eq(1)
    expect(user_texts.count("Second queued")).to eq(0)
  end

  it "broadcasts chat controls before Codex pre-spawn work and when the agent process starts" do
    codex_user = Factories.user(codex_api_key: "sk-test", github_token: "ghp-test", chat_provider: "codex")
    codex_repository = Factories.repository(user: codex_user, owner: "acme", name: "broadcast-widgets", default_branch: "main")
    codex_chat = ChatSession.create!(repository: codex_repository, user: codex_user)
    message = codex_chat.messages.create!(role: "user", content: { text: "Use Codex" })
    codex_workspace_path = workspace_root.join("codex-broadcast-chat")
    allow(ChatWorkspace).to receive(:path_for).with(codex_chat).and_return(codex_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(codex_chat).and_return(codex_workspace_path)
    events = []
    allow(AppEvents).to receive(:broadcast) { |**kwargs| events << kwargs }
    ChatTurnJob.agent_runner = ->(workspace_path:, process_started:, log_sink:, **_) {
      process = SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        workdir: workspace_path,
        hostname: "worker-1",
        started_at: Time.current
      )
      process_started.call(process)
      process.update!(finished_at: Time.current, outcome: "succeeded")
      log_sink.call("Codex is ready.", kind: "assistant_text")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(codex_chat.id, message.id)

    control_events = events.select { |event| event[:changed] == [ "controls" ] }
    expect(control_events.map { |event| event.dig(:payload, :turn_in_flight) || event.dig(:payload, :agent_busy) }).to eq([ true, true, false ])
    expect(control_events.first.dig(:payload, :agent_busy)).to eq(false)
  end

  it "resumes the existing Claude session with a fresh snapshot and without the full system prompt" do
    chat.create_claude_session!(
      provider: "claude",
      session_id: "chat-session-1",
      transcript_jsonl: "old"
    )
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-2", transcript_jsonl: "new")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:resume_session_id]).to eq("chat-session-1")
    expect(received[:prompt]).to include("Agent environment snapshot:")
    expect(received[:prompt]).to include("Chat: ##{chat.id} scoped to acme/widgets")
    expect(received[:prompt]).to include("What is the plan?")
    expect(received[:prompt]).not_to include("You are Syrus Chat")
    expect(chat.reload.claude_session).to have_attributes(
      session_id: "chat-session-2",
      transcript_jsonl: "new"
    )
  end

  it "includes compact persisted chat history when resuming a Claude session" do
    chat.messages.create!(role: "user", content: { text: "Earlier: focus on billing exports." })
    chat.messages.create!(role: "assistant", content: { text: "I found the CSV exporter and suggested adding filters." })
    chat.messages.create!(
      role: "system",
      content: {
        text: %(Proposal "Billing export" was confirmed as JOB-123 (proposal slug: billing-export).),
        source: "proposal_notification"
      }
    )
    chat.create_claude_session!(provider: "claude", session_id: "chat-session-1", transcript_jsonl: "old")

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-2", transcript_jsonl: "new")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:resume_session_id]).to eq("chat-session-1")
    expect(received[:prompt]).to include("Recent persisted chat context fallback:")
    expect(received[:prompt]).to include("user: Earlier: focus on billing exports.")
    expect(received[:prompt]).to include("assistant: I found the CSV exporter")
    expect(received[:prompt]).to include("system: Proposal \"Billing export\" was confirmed as JOB-123")
    expect(received[:prompt]).to include("What is the plan?")
    expect(received[:prompt]).not_to include("You are Syrus Chat")
  end

  it "summarizes tool calls and caps large tool results in resumed chat history" do
    huge_tool_result = "A" * 2_000
    chat.messages.create!(role: "user", content: { text: "Please inspect app/jobs/chat_turn_job.rb." })
    chat.messages.create!(
      role: "tool_use",
      tool_name: "Read",
      content: { input: { "file_path" => "app/jobs/chat_turn_job.rb", "irrelevant" => "x" * 1_500 } }
    )
    chat.messages.create!(
      role: "tool_result",
      tool_name: "Read",
      content: { result: [ { type: "text", text: huge_tool_result } ], is_error: false }
    )
    chat.create_claude_session!(provider: "claude", session_id: "chat-session-1", transcript_jsonl: "old")

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-2", transcript_jsonl: "new")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:prompt]).to include("tool_use: Read")
    expect(received[:prompt]).to include("app/jobs/chat_turn_job.rb")
    expect(received[:prompt]).to include("tool_result: Read ok:")
    expect(received[:prompt]).to include("...[truncated]")
    expect(received[:prompt]).not_to include("A" * 1_200)
    expect(received[:prompt]).not_to include("irrelevant")
  end

  it "runs proposal outcome control turns with a terse acknowledgment prompt" do
    control_message = chat.messages.create!(
      role: "system",
      content: {
        "text" => "Proposal confirmed. JOB-1416 \"Map auth\" was created.",
        "source" => "proposal_notification",
        "outcome" => "confirmed",
        "acknowledgment" => "Confirmed JOB-1416."
      }
    )
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      kwargs[:log_sink].call("Confirmed JOB-1416.", kind: "assistant_text")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "{\"type\":\"system\"}\n")
    }

    described_class.perform_now(chat.id, control_message.id)

    expect(received[:prompt]).to include("This is a Syrus control event, not an operator-authored chat message.")
    expect(received[:prompt]).to include("Default behavior: reply with exactly:\nConfirmed JOB-1416.")
    expect(received[:prompt]).to include("Only do more if this outcome unlocks concrete follow-up automation")
    expect(received[:prompt]).to include("Do not restate your operating instructions")
    expect(received[:prompt]).not_to include("You are Syrus Chat")
    expect(chat.messages.order(:created_at).pluck(:role)).to eq([ "system", "assistant" ])
    expect(chat.messages.order(:created_at).last.content).to eq([ { "type" => "text", "text" => "Confirmed JOB-1416." } ])
  end

  it "runs Codex chat turns with chat MCP servers and captures a Codex session" do
    codex_user = Factories.user(codex_api_key: "sk-test", github_token: "ghp-test", chat_provider: "codex")
    codex_repository = Factories.repository(user: codex_user, owner: "acme", name: "codex-widgets", default_branch: "main")
    codex_chat = ChatSession.create!(repository: codex_repository, user: codex_user)
    codex_message = codex_chat.messages.create!(role: "user", content: { text: "Use Codex for this" })
    codex_workspace_path = workspace_root.join("codex-chat")
    allow(ChatWorkspace).to receive(:path_for).with(codex_chat).and_return(codex_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(codex_chat).and_return(codex_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      kwargs[:log_sink].call("Codex response", kind: "assistant_text")
      kwargs[:log_sink].call(
        "[codex mcp] syrus-chat-sidecar.repo_info started",
        kind: "tool_call",
        tool_name: "mcp__syrus-chat-sidecar__repo_info",
        tool_input: { "repository_id" => codex_repository.id, "status" => "started" },
        tool_use_id: "call_1"
      )
      kwargs[:log_sink].call(
        "[codex mcp] syrus-chat-sidecar.repo_info completed",
        kind: "tool_result",
        tool_name: "mcp__syrus-chat-sidecar__repo_info",
        tool_result_content: { "slug" => codex_repository.slug },
        tool_result_error: false,
        tool_use_id: "call_1"
      )
      kwargs[:log_sink].call(
        "[codex command] bin/rails test started",
        kind: "tool_call",
        tool_name: "Command",
        tool_input: { "command" => "bin/rails test", "status" => "started" },
        tool_use_id: "cmd_1"
      )
      result_fixture(session_id: "codex-thread-1", transcript_jsonl: "{\"type\":\"session_meta\"}\n")
    }

    described_class.perform_now(codex_chat.id, codex_message.id)

    expect(received).to include(
      workspace_path: codex_workspace_path.to_s,
      prompt: include("Use Codex for this"),
      api_key: "sk-test",
      codex_home: ChatWorkspace.agent_home_for(codex_chat, "codex").to_s,
      resume_session_id: nil
    )
    expect(received[:mcp_servers]).to include(
      "syrus-chat-sidecar" => include(
        command: Rails.root.join("bin/syrus-chat-sidecar").to_s,
        args: [],
        required: true
      ),
      "syrus-chat-deferred-sidecar" => include(
        command: Rails.root.join("bin/syrus-chat-deferred-sidecar").to_s,
        args: [],
        required: false
      )
    )
    expect(received.dig(:mcp_servers, "syrus-chat-sidecar", :env)).to include(
      "SYRUS_CHAT_SESSION_ID" => codex_chat.id.to_s,
      "SYRUS_CHAT_CURRENT_MESSAGE_ID" => codex_message.id.to_s,
      "SYRUS_CHAT_MCP_SERVER_NAME" => "syrus-chat-sidecar",
      "PATH" => ENV.fetch("PATH")
    )
    messages = codex_chat.messages.order(:created_at).to_a
    expect(messages.map(&:role)).to eq([ "user", "assistant", "tool_use", "tool_result", "tool_use" ])
    expect(messages.third).to have_attributes(
      tool_name: "mcp__syrus-chat-sidecar__repo_info",
      content: {
        "type" => "tool_use",
        "id" => "call_1",
        "name" => "mcp__syrus-chat-sidecar__repo_info",
        "input" => { "repository_id" => codex_repository.id, "status" => "started" }
      }
    )
    expect(messages.fourth).to have_attributes(
      tool_name: "mcp__syrus-chat-sidecar__repo_info",
      content: {
        "type" => "tool_result",
        "tool_use_id" => "call_1",
        "content" => { "slug" => codex_repository.slug },
        "is_error" => false
      }
    )
    expect(messages.fifth).to have_attributes(
      tool_name: "Command",
      content: {
        "type" => "tool_use",
        "id" => "cmd_1",
        "name" => "Command",
        "input" => { "command" => "bin/rails test", "status" => "started" }
      }
    )
    expect(codex_chat.reload.claude_session).to have_attributes(
      provider: "codex",
      session_id: "codex-thread-1",
      transcript_jsonl: "{\"type\":\"session_meta\"}\n"
    )
  end

  it "uses the chat-level provider override for a turn" do
    mixed_user = Factories.user(
      agent_provider: "claude",
      chat_provider: nil,
      claude_oauth_token: "oat-test",
      codex_api_key: "sk-test",
      github_token: "ghp-test"
    )
    mixed_repository = Factories.repository(user: mixed_user, owner: "acme", name: "provider-override", default_branch: "main")
    mixed_chat = ChatSession.create!(repository: mixed_repository, user: mixed_user, chat_provider: "codex")
    mixed_message = mixed_chat.messages.create!(role: "user", content: { text: "Use the chat override" })
    mixed_workspace_path = workspace_root.join("provider-override-chat")
    allow(ChatWorkspace).to receive(:path_for).with(mixed_chat).and_return(mixed_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(mixed_chat).and_return(mixed_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "codex-thread-override", transcript_jsonl: "{\"type\":\"session_meta\"}\n")
    }

    described_class.perform_now(mixed_chat.id, mixed_message.id)

    expect(received).to include(
      api_key: "sk-test",
      codex_home: ChatWorkspace.agent_home_for(mixed_chat, "codex").to_s
    )
    expect(mixed_chat.reload.claude_session.provider).to eq("codex")
  end

  it "pins the user default chat provider when the chat provider is blank" do
    codex_user = Factories.user(
      agent_provider: "codex",
      chat_provider: nil,
      codex_api_key: "sk-test",
      github_token: "ghp-test"
    )
    codex_repository = Factories.repository(user: codex_user, owner: "acme", name: "default-provider", default_branch: "main")
    codex_chat = ChatSession.create!(repository: codex_repository, user: codex_user, chat_provider: nil)
    codex_message = codex_chat.messages.create!(role: "user", content: { text: "Use my default" })
    codex_workspace_path = workspace_root.join("default-provider-chat")
    allow(ChatWorkspace).to receive(:path_for).with(codex_chat).and_return(codex_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(codex_chat).and_return(codex_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "codex-thread-default", transcript_jsonl: "{\"type\":\"session_meta\"}\n")
    }

    described_class.perform_now(codex_chat.id, codex_message.id)

    expect(received).to include(
      api_key: "sk-test",
      codex_home: ChatWorkspace.agent_home_for(codex_chat, "codex").to_s
    )
    expect(codex_chat.reload.chat_provider).to eq("codex")
    expect(codex_chat.reload.claude_session.provider).to eq("codex")
  end

  it "continues a blank-provider Claude chat with Claude after the user default changes to Codex" do
    stable_user = Factories.user(
      agent_provider: "claude",
      chat_provider: "claude",
      claude_oauth_token: "oat-test",
      codex_api_key: "sk-test",
      github_token: "ghp-test"
    )
    stable_repository = Factories.repository(user: stable_user, owner: "acme", name: "claude-stable", default_branch: "main")
    stable_chat = ChatSession.create!(repository: stable_repository, user: stable_user, chat_provider: nil)
    stable_chat.messages.create!(role: "user", content: { text: "Start on Claude" })
    stable_chat.pin_chat_provider!
    stable_user.update!(chat_provider: "codex")
    followup = stable_chat.messages.create!(role: "user", content: { text: "Continue after default changed" })
    stable_workspace_path = workspace_root.join("claude-stable-chat")
    allow(ChatWorkspace).to receive(:path_for).with(stable_chat).and_return(stable_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(stable_chat).and_return(stable_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "claude-stable-session", transcript_jsonl: "x")
    }

    described_class.perform_now(stable_chat.id, followup.id)

    expect(received).to include(oauth_token: "oat-test")
    expect(received).not_to include(:api_key)
    expect(stable_chat.reload.chat_provider).to eq("claude")
    expect(stable_chat.claude_session.provider).to eq("claude")
  end

  it "continues a blank-provider Codex chat with Codex after the user default changes to Claude" do
    stable_user = Factories.user(
      agent_provider: "codex",
      chat_provider: "codex",
      claude_oauth_token: "oat-test",
      codex_api_key: "sk-test",
      github_token: "ghp-test"
    )
    stable_repository = Factories.repository(user: stable_user, owner: "acme", name: "codex-stable", default_branch: "main")
    stable_chat = ChatSession.create!(repository: stable_repository, user: stable_user, chat_provider: nil)
    stable_chat.messages.create!(role: "user", content: { text: "Start on Codex" })
    stable_chat.pin_chat_provider!
    stable_user.update!(chat_provider: "claude")
    followup = stable_chat.messages.create!(role: "user", content: { text: "Continue after default changed" })
    stable_workspace_path = workspace_root.join("codex-stable-chat")
    allow(ChatWorkspace).to receive(:path_for).with(stable_chat).and_return(stable_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(stable_chat).and_return(stable_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "codex-stable-session", transcript_jsonl: "{\"type\":\"session_meta\"}\n")
    }

    described_class.perform_now(stable_chat.id, followup.id)

    expect(received).to include(
      api_key: "sk-test",
      codex_home: ChatWorkspace.agent_home_for(stable_chat, "codex").to_s
    )
    expect(received).not_to include(:oauth_token)
    expect(stable_chat.reload.chat_provider).to eq("codex")
    expect(stable_chat.claude_session.provider).to eq("codex")
  end

  it "includes compact persisted chat history when resuming a Codex session" do
    codex_user = Factories.user(codex_api_key: "sk-test", github_token: "ghp-test", chat_provider: "codex")
    codex_repository = Factories.repository(user: codex_user, owner: "acme", name: "codex-context", default_branch: "main")
    codex_chat = ChatSession.create!(repository: codex_repository, user: codex_user)
    codex_chat.messages.create!(role: "user", content: { text: "Earlier Codex request: inspect the queue filters." })
    codex_chat.messages.create!(role: "assistant", content: { text: "The queue filters are in Admin::Queue::Filter." })
    codex_chat.create_claude_session!(
      provider: "codex",
      session_id: "codex-thread-1",
      transcript_jsonl: "{\"type\":\"session_meta\"}\n"
    )
    codex_message = codex_chat.messages.create!(role: "user", content: { text: "Continue from there." })
    codex_workspace_path = workspace_root.join("codex-context-chat")
    allow(ChatWorkspace).to receive(:path_for).with(codex_chat).and_return(codex_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(codex_chat).and_return(codex_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "codex-thread-2", transcript_jsonl: "{\"type\":\"turn\"}\n")
    }

    described_class.perform_now(codex_chat.id, codex_message.id)

    expect(received[:resume_session_id]).to eq("codex-thread-1")
    expect(received[:resume_transcript_jsonl]).to include("session_meta")
    expect(received[:prompt]).to include("Recent persisted chat context fallback:")
    expect(received[:prompt]).to include("user: Earlier Codex request: inspect the queue filters.")
    expect(received[:prompt]).to include("assistant: The queue filters are in Admin::Queue::Filter.")
    expect(received[:prompt]).to include("Continue from there.")
    expect(received[:prompt]).not_to include("You are Syrus Chat")
  end

  it "rehydrates a Codex transcript from ChatMessages when the prior session was Claude" do
    codex_user = Factories.user(codex_api_key: "sk-test", github_token: "ghp-test", chat_provider: "codex")
    codex_repository = Factories.repository(user: codex_user, owner: "acme", name: "mixed-provider", default_branch: "main")
    codex_chat = ChatSession.create!(repository: codex_repository, user: codex_user)
    codex_chat.create_claude_session!(
      provider: "claude",
      session_id: "claude-session-1",
      transcript_jsonl: "old"
    )
    codex_chat.messages.create!(role: "assistant", content: [{ "type" => "text", "text" => "Here is what I found." }])
    codex_message = codex_chat.messages.create!(role: "user", content: { text: "Continue in Codex" })
    codex_workspace_path = workspace_root.join("mixed-provider-chat")
    allow(ChatWorkspace).to receive(:path_for).with(codex_chat).and_return(codex_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(codex_chat).and_return(codex_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "codex-thread-1", transcript_jsonl: "new")
    }

    described_class.perform_now(codex_chat.id, codex_message.id)

    # Session_id is passed through regardless of provider so rehydration can use it as thread_id
    expect(received[:resume_session_id]).to eq("claude-session-1")
    # Rehydrated Codex JSONL from ChatMessage rows
    expect(received[:resume_transcript_jsonl]).to be_present
    rehydrated = received[:resume_transcript_jsonl].lines.map { |l| JSON.parse(l) }
    expect(rehydrated.first).to include("type" => "thread.started", "thread_id" => "claude-session-1")
    expect(rehydrated.last).to include("type" => "turn.completed")
    # Elaboration-guidance path instead of full system prompt (we have a session to resume)
    expect(received[:prompt]).not_to include("You are Syrus Chat")
    expect(codex_chat.reload.claude_session).to have_attributes(
      provider: "codex",
      session_id: "codex-thread-1",
      transcript_jsonl: "new"
    )
  end

  it "uses the cached Codex transcript directly on same-provider resume" do
    codex_user = Factories.user(codex_api_key: "sk-test", github_token: "ghp-test", chat_provider: "codex")
    codex_repository = Factories.repository(user: codex_user, owner: "acme", name: "codex-resume", default_branch: "main")
    codex_chat = ChatSession.create!(repository: codex_repository, user: codex_user)
    codex_chat.create_claude_session!(
      provider: "codex",
      session_id: "codex-thread-1",
      transcript_jsonl: "{\"type\":\"thread.started\"}\n"
    )
    codex_message = codex_chat.messages.create!(role: "user", content: { text: "Next Codex turn" })
    codex_workspace_path = workspace_root.join("codex-resume-chat")
    allow(ChatWorkspace).to receive(:path_for).with(codex_chat).and_return(codex_workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(codex_chat).and_return(codex_workspace_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "codex-thread-1", transcript_jsonl: "updated")
    }

    described_class.perform_now(codex_chat.id, codex_message.id)

    expect(received[:resume_session_id]).to eq("codex-thread-1")
    # Uses the cached transcript directly (fast path), not a freshly rehydrated one
    expect(received[:resume_transcript_jsonl]).to eq("{\"type\":\"thread.started\"}\n")
  end

  it "writes a rehydrated Claude JSONL to disk when resuming after a Codex session" do
    Dir.mktmpdir("syrus-claude-home") do |home|
      saved_home = ENV["HOME"]
      ENV["HOME"] = home

      codex_chat = ChatSession.create!(repository: repository, user: user)
      codex_chat.create_claude_session!(provider: "codex", session_id: "codex-thread-1", transcript_jsonl: "codex-data")
      codex_chat.messages.create!(role: "assistant", content: [{ "type" => "text", "text" => "Codex was here." }])
      claude_message = codex_chat.messages.create!(role: "user", content: { text: "Now use Claude" })
      allow(ChatWorkspace).to receive(:path_for).with(codex_chat).and_return(workspace_path)
      allow(ChatWorkspace).to receive(:ensure_root!).with(codex_chat).and_return(workspace_path)

      written_before_run = nil
      ChatTurnJob.agent_runner = ->(**kwargs) {
        path = ClaudeSession.canonical_path_for(home: home, cwd: workspace_path, session_id: "codex-thread-1")
        written_before_run = File.read(path) if File.exist?(path)
        result_fixture(session_id: "codex-thread-1", transcript_jsonl: "x")
      }

      described_class.perform_now(codex_chat.id, claude_message.id)

      # The rehydrated Claude JSONL must be on disk before the runner is called
      expect(written_before_run).to be_present
      rehydrated = written_before_run.lines.map { |l| JSON.parse(l) }
      expect(rehydrated.first).to include("type" => "system", "subtype" => "init", "session_id" => "codex-thread-1")
    ensure
      ENV["HOME"] = saved_home
    end
  end

  it "writes a rehydrated Claude JSONL to disk when the session file is missing for same-provider resume" do
    Dir.mktmpdir("syrus-claude-home") do |home|
      saved_home = ENV["HOME"]
      ENV["HOME"] = home

      chat.create_claude_session!(provider: "claude", session_id: "missing-session-1", transcript_jsonl: "old-cached")
      chat.messages.create!(role: "assistant", content: [{ "type" => "text", "text" => "Prior response." }])
      next_message = chat.messages.create!(role: "user", content: { text: "Resume please" })

      # No JSONL file on disk — simulate a missing disk file (worker restart, etc.)
      path = ClaudeSession.canonical_path_for(home: home, cwd: workspace_path, session_id: "missing-session-1")
      expect(File.exist?(path)).to eq(false)

      written_before_run = nil
      ChatTurnJob.agent_runner = ->(**kwargs) {
        written_before_run = File.read(path) if File.exist?(path)
        result_fixture(session_id: "missing-session-1", transcript_jsonl: "x")
      }

      described_class.perform_now(chat.id, next_message.id)

      expect(written_before_run).to be_present
      rehydrated = written_before_run.lines.map { |l| JSON.parse(l) }
      expect(rehydrated.first).to include("type" => "system", "subtype" => "init", "session_id" => "missing-session-1")
    ensure
      ENV["HOME"] = saved_home
    end
  end

  it "does not persist nameless tool call events" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("[codex mcp] started", kind: "tool_call", tool_input: { "status" => "started" })
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "{}\n")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.messages.where(role: "tool_use")).to be_empty
  end

  it "records available and unavailable MCP tools while suppressing pending-only MCP health" do
    Dir.mktmpdir("syrus-mcp-sidecar-logs") do |dir|
      saved_data_root = ENV["SYRUS_DATA_ROOT"]
      ENV["SYRUS_DATA_ROOT"] = dir

      ChatTurnJob.agent_runner = ->(log_sink:, **_) {
        log_sink.call(
          "[mcp_servers] syrus-chat-sidecar=pending syrus-chat-deferred-sidecar=pending",
          kind: "system",
          mcp_servers: [
            { "name" => "syrus-chat-sidecar", "status" => "pending" },
            { "name" => "syrus-chat-deferred-sidecar", "status" => "pending" }
          ]
        )
        log_sink.call(
          "[mcp_servers] syrus-chat-sidecar=connected syrus-chat-deferred-sidecar=connected",
          kind: "system",
          mcp_servers: [
            { "name" => "syrus-chat-sidecar", "status" => "connected" },
            { "name" => "syrus-chat-deferred-sidecar", "status" => "connected" }
          ]
        )
        log_sink.call(
          "[mcp_servers] syrus-chat-sidecar=failed syrus-chat-deferred-sidecar=failed",
          kind: "system",
          mcp_servers: [
            { "name" => "syrus-chat-sidecar", "status" => "failed" },
            { "name" => "syrus-chat-deferred-sidecar", "status" => "failed" }
          ]
        )
        result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
      }

      described_class.perform_now(chat.id, user_message.id)

      mcp_messages = chat.messages.where(role: "system").order(:id).last(2)
      expect(mcp_messages.map { |message| message.content["text"] }).to eq([
        "[mcp_servers] syrus-chat-sidecar=connected syrus-chat-deferred-sidecar=connected",
        "[mcp_servers] syrus-chat-sidecar=failed syrus-chat-deferred-sidecar=failed"
      ])

      connected, failed = mcp_messages
      expect(connected.content.dig("mcp_health", 0)).to include(
        "name" => "syrus-chat-sidecar",
        "status" => "connected",
        "available_tools" => include("propose_job", "repo_info"),
        "pending_tools" => [],
        "unavailable_tools" => []
      )
      expect(connected.content.dig("mcp_health", 1)).to include(
        "name" => "syrus-chat-deferred-sidecar",
        "status" => "connected",
        "available_tools" => include("draw_shape", "read_workflow"),
        "pending_tools" => [],
        "unavailable_tools" => []
      )
      expect(failed.content.dig("mcp_health", 0)).to include(
        "status" => "failed",
        "available_tools" => [],
        "pending_tools" => [],
        "unavailable_tools" => include("propose_job", "repo_info")
      )
      expect(failed.content.dig("mcp_health", 1)).to include(
        "status" => "failed",
        "available_tools" => [],
        "pending_tools" => [],
        "unavailable_tools" => include("draw_shape", "read_workflow")
      )
    ensure
      ENV["SYRUS_DATA_ROOT"] = saved_data_root
    end
  end

  it "attaches failed MCP sidecar stderr to unavailable MCP health messages" do
    Dir.mktmpdir("syrus-mcp-sidecar-logs") do |dir|
      saved_data_root = ENV["SYRUS_DATA_ROOT"]
      ENV["SYRUS_DATA_ROOT"] = dir
      path = McpSidecarLog.chat_path_for(
        chat.id,
        message_id: user_message.id,
        server_name: "syrus-chat-sidecar"
      )
      path.dirname.mkpath
      path.write("boot failed\nstack line\n")

      ChatTurnJob.agent_runner = ->(log_sink:, **_) {
        log_sink.call(
          "[mcp_servers] syrus-chat-sidecar=failed",
          kind: "system",
          mcp_servers: [
            { "name" => "syrus-chat-sidecar", "status" => "failed" }
          ]
        )
        result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
      }

      described_class.perform_now(chat.id, user_message.id)

      message = chat.messages.where(role: "system").order(:id).last
      expect(message.content["text"]).to include("[mcp_sidecar_stderr]")
      expect(message.content["mcp_sidecar_stderr"]).to include(
        "syrus-chat-sidecar:\nboot failed\nstack line\n"
      )
    ensure
      ENV["SYRUS_DATA_ROOT"] = saved_data_root
    end
  end

  it "maps MCP server names to advertised chat tool names" do
    job = described_class.new
    job.instance_variable_set(:@chat, chat)

    expect(job.send(:mcp_tool_names_for, "syrus-chat-sidecar")).to include("propose_job", "repo_info", "rename_chat")
    expect(job.send(:mcp_tool_names_for, "syrus-chat-sidecar")).not_to include("draw_shape")
    expect(job.send(:mcp_tool_names_for, "syrus-chat-deferred-sidecar")).to include("draw_shape", "read_workflow", "assign_job_to_epic")
    expect(job.send(:mcp_tool_names_for, "syrus-chat-deferred-sidecar")).not_to include("repo_info", "rename_chat")
    expect(job.send(:mcp_tool_names_for, "unknown-sidecar")).to eq([])
  end

  it "captures Claude's canonical transcript when the result omits transcript data" do
    Dir.mktmpdir("syrus-chat-home") do |home|
      saved_home = ENV["HOME"]
      ENV["HOME"] = home
      transcript_path = ClaudeSession.canonical_path_for(
        home: home,
        cwd: workspace_path,
        session_id: "chat-session-1"
      )
      FileUtils.mkdir_p(File.dirname(transcript_path))
      File.write(transcript_path, "{\"type\":\"system\"}\n")

      ChatTurnJob.agent_runner = ->(**_) {
        result_fixture(session_id: "chat-session-1")
      }

      described_class.perform_now(chat.id, user_message.id)

      expect(chat.reload.claude_session.transcript_jsonl).to eq("{\"type\":\"system\"}\n")
    ensure
      ENV["HOME"] = saved_home
    end
  end

  it "keeps the resumable session when optional normalized metadata persistence fails" do
    allow_any_instance_of(ClaudeSession).to receive(:update!).and_wrap_original do |original, *args|
      attrs = args.first
      raise ActiveRecord::ValueTooLong, "normalized metadata too large" if attrs.is_a?(Hash) && attrs.key?(:normalized_messages)

      original.call(*args)
    end

    ChatTurnJob.agent_runner = ->(**_) {
      result_fixture(
        session_id: "chat-session-1",
        transcript_jsonl: "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"chat-session-1\"}\n"
      )
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.reload.claude_session).to have_attributes(
      provider: "claude",
      session_id: "chat-session-1",
      transcript_jsonl: "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"chat-session-1\"}\n"
    )
  end

  it "passes effort_level to the agent runner when chat_effort is set" do
    chat.update!(chat_effort: "high")
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:effort_level]).to eq("high")
  end

  it "passes nil effort_level to the agent runner when chat_effort is not set" do
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "s1")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:effort_level]).to be_nil
  end

  it "writes a system message and skips the agent when Claude credentials are missing" do
    user.update!(claude_oauth_token: nil)
    called = false
    ChatTurnJob.agent_runner = ->(**_) { called = true }

    described_class.perform_now(chat.id, user_message.id)

    expect(called).to eq(false)
    expect(chat.messages.last).to have_attributes(
      role: "system",
      content: include("text" => match(/Claude credentials are missing/))
    )
  end

  it "stores assistant messages in canonical content-blocks array format" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("Here is the answer.", kind: "assistant_text")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    assistant_msg = chat.messages.find_by(role: "assistant")
    expect(assistant_msg.content).to eq([ { "type" => "text", "text" => "Here is the answer." } ])
  end

  it "accumulates thinking blocks and text blocks into one assistant message" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("Reasoning...", kind: "thinking", thinking: "Reasoning...", signature: "sig-xyz")
      log_sink.call("Conclusion.", kind: "assistant_text")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    assistant_msg = chat.messages.find_by(role: "assistant")
    expect(assistant_msg.content).to eq([
      { "type" => "thinking", "thinking" => "Reasoning...", "signature" => "sig-xyz" },
      { "type" => "text", "text" => "Conclusion." }
    ])
    expect(chat.messages.where(role: "assistant").count).to eq(1)
  end

  it "omits signature from thinking block when it is absent" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("Thinking...", kind: "thinking", thinking: "Thinking...", signature: nil)
      log_sink.call("Done.", kind: "assistant_text")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    block = chat.messages.find_by(role: "assistant").content.first
    expect(block).to eq({ "type" => "thinking", "thinking" => "Thinking..." })
    expect(block).not_to have_key("signature")
  end

  it "flushes accumulated assistant content before a tool_use message" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("Thinking...", kind: "thinking", thinking: "Thinking...", signature: "s")
      log_sink.call("Using tool.", kind: "assistant_text")
      log_sink.call("● Read(...)", kind: "tool_call", tool_name: "Read", tool_input: { "file_path" => "/x" }, tool_use_id: "toolu_1")
      log_sink.call("content", kind: "tool_result", tool_name: "Read", tool_result_content: "content", tool_result_error: false, tool_use_id: "toolu_1")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    roles = chat.messages.order(:created_at, :id).pluck(:role)
    expect(roles).to eq(%w[user assistant tool_use tool_result])
  end

  it "stores tool_use messages in canonical content-blocks format with id, name, and input" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("● propose_job(...)", kind: "tool_call",
                    tool_name: "propose_job",
                    tool_input: { "title" => "T" },
                    tool_use_id: "toolu_abc")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    tool_use_msg = chat.messages.find_by(role: "tool_use")
    expect(tool_use_msg.content).to eq({
      "type" => "tool_use",
      "id" => "toolu_abc",
      "name" => "propose_job",
      "input" => { "title" => "T" }
    })
    expect(tool_use_msg.tool_use_id).to eq("toolu_abc")
  end

  it "stores tool_result messages in canonical content-blocks format with type, tool_use_id, content, and is_error" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("● Read(...)", kind: "tool_call", tool_name: "Read",
                    tool_input: { "file_path" => "/x" }, tool_use_id: "toolu_r1")
      log_sink.call("file content", kind: "tool_result", tool_name: "Read",
                    tool_result_content: [ { "type" => "text", "text" => "file content" } ],
                    tool_result_error: false, tool_use_id: "toolu_r1")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    tool_result_msg = chat.messages.find_by(role: "tool_result")
    expect(tool_result_msg.content).to eq({
      "type" => "tool_result",
      "tool_use_id" => "toolu_r1",
      "content" => [ { "type" => "text", "text" => "file content" } ],
      "is_error" => false
    })
    expect(tool_result_msg.tool_use_id).to eq("toolu_r1")
  end

  it "records chat MCP usage while preserving tool messages" do
    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("● repo_info(...)", kind: "tool_call",
                                      tool_name: "mcp__syrus-chat-sidecar__repo_info",
                                      tool_input: { "repo" => repository.slug },
                                      tool_use_id: "mcp_1")
      log_sink.call("ok", kind: "tool_result",
                          tool_name: "mcp__syrus-chat-sidecar__repo_info",
                          tool_result_content: { "slug" => repository.slug },
                          tool_result_error: false,
                          tool_use_id: "mcp_1")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    usage = McpToolUsage.sole
    expect(usage).to have_attributes(
      surface: "chat",
      provider: chat.effective_chat_provider,
      server_name: "syrus-chat-sidecar",
      normalized_tool_name: "repo_info",
      status: "completed",
      error: false,
      chat_session_id: chat.id,
      repository_id: repository.id,
      user_id: user.id
    )
    expect(chat.messages.where(role: %w[tool_use tool_result]).count).to eq(2)
  end

  it "moves pending action cards from the initiating user message to the producing tool call" do
    job = Factories.job(repository: repository)
    pending_action = chat.pending_actions.create!(
      action: "rebase_job",
      payload: { "job_id" => job.id },
      requested_by: "agent"
    )
    user_message.update!(pending_action: pending_action)

    ChatTurnJob.agent_runner = ->(log_sink:, **_) {
      log_sink.call("I will request the rebase.", kind: "assistant_text")
      log_sink.call("● rebase_job(...)", kind: "tool_call",
                    tool_name: "syrus-chat-sidecar.rebase_job",
                    tool_input: { "job_id" => job.id },
                    tool_use_id: "toolu_rebase")
      log_sink.call("Job rebase requires operator confirmation.", kind: "tool_result",
                    tool_name: "syrus-chat-sidecar.rebase_job",
                    tool_result_content: JSON.generate(
                      pending_confirmation_id: pending_action.id,
                      pending_action_id: pending_action.id,
                      state: "pending",
                      message: "Job rebase requires operator confirmation."
                    ),
                    tool_result_error: false,
                    tool_use_id: "toolu_rebase")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    tool_use_msg = chat.messages.find_by!(role: "tool_use", tool_use_id: "toolu_rebase")
    expect(tool_use_msg.pending_action).to eq(pending_action)
    expect(user_message.reload.pending_action).to be_nil
    expect(pending_action.reload.message).to eq(tool_use_msg)
  end

  it "flushes partial assistant content before the cancellation system message on stop" do
    ChatTurnJob.agent_runner = ->(log_sink:, stop_requested:, **_) {
      log_sink.call("Working...", kind: "thinking", thinking: "Working...", signature: "s")
      log_sink.call("In progress.", kind: "assistant_text")
      chat.update!(stop_requested_at: 1.second.from_now)

      expect(stop_requested.call).to eq(true)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    roles = chat.messages.order(:created_at, :id).pluck(:role)
    system_idx = roles.index("system")
    assistant_idx = roles.index("assistant")
    expect(assistant_idx).to be < system_idx, "assistant message should precede the cancellation system message"
    expect(chat.messages.find_by(role: "system").content["text"]).to eq("Cancelled by operator.")
  end

  it "polls stop_requested_at between stream events and records cancellation" do
    ChatTurnJob.agent_runner = ->(log_sink:, stop_requested:, **_) {
      log_sink.call("Working...", kind: "assistant_text")
      chat.update!(stop_requested_at: 1.second.from_now)

      expect(stop_requested.call).to eq(true)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ]
    )
  end

  it "clears stale stop requests at turn start" do
    chat.update!(stop_requested_at: 5.minutes.ago)
    ChatTurnJob.agent_runner = ->(stop_requested:, **_) {
      expect(stop_requested.call).to eq(false)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.reload.stop_requested_at).to be_nil
  end

  describe "#tool_result_summary" do
    subject(:job) do
      j = described_class.new
      j.instance_variable_set(:@chat, chat)
      j.instance_variable_set(:@user_message, user_message)
      j
    end

    it "extracts text from the canonical 'content' key used by ChatTurnJob" do
      message = chat.messages.create!(
        role: "tool_result",
        tool_name: "Read",
        tool_use_id: "tu_abc",
        content: {
          "type" => "tool_result",
          "tool_use_id" => "tu_abc",
          "content" => [{ "type" => "text", "text" => "file contents here" }],
          "is_error" => false
        }
      )

      summary = job.send(:tool_result_summary, message)
      expect(summary).to include("file contents here")
      expect(summary).to include("ok")
    end

    it "falls back to the legacy 'result' key for older messages" do
      message = chat.messages.create!(
        role: "tool_result",
        tool_name: "Bash",
        tool_use_id: "tu_def",
        content: {
          "type" => "tool_result",
          "tool_use_id" => "tu_def",
          "result" => "hello",
          "is_error" => false
        }
      )

      summary = job.send(:tool_result_summary, message)
      expect(summary).to include("hello")
    end

    it "reports error status when is_error is true" do
      message = chat.messages.create!(
        role: "tool_result",
        tool_name: "Bash",
        tool_use_id: "tu_err",
        content: {
          "type" => "tool_result",
          "tool_use_id" => "tu_err",
          "content" => [{ "type" => "text", "text" => "command not found" }],
          "is_error" => true
        }
      )

      summary = job.send(:tool_result_summary, message)
      expect(summary).to include("error")
    end
  end

  def result_fixture(**overrides)
    attrs = {
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: nil
    }.merge(overrides)
    AgentInvocation::Result.new(**attrs)
  end
end
