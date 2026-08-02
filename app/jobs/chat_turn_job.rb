require "base64"
require "fileutils"
require "open3"
require "securerandom"
require "tempfile"
require "tmpdir"

class ChatTurnJob < ApplicationJob
  include HistoryFallback

  CONCURRENCY_GROUP = "repository_chat"
  HISTORY_FALLBACK_MESSAGE_LIMIT = 24
  HISTORY_FALLBACK_MAX_BYTES = 12_000
  HISTORY_FALLBACK_ENTRY_MAX_BYTES = 1_000
  HISTORY_FALLBACK_TOOL_RESULT_MAX_BYTES = 400

  queue_as :chat
  discard_on StandardError

  limits_concurrency to: 1, group: CONCURRENCY_GROUP, key: ->(chat_session_id, *) {
    "chat:#{chat_session_id}"
  }, duration: 30.minutes

  class << self
    attr_accessor :agent_runner

    def claude_file_flag_supported?
      return @claude_file_flag_supported unless @claude_file_flag_supported.nil?

      output, status = Open3.capture2e("claude", "--help")
      @claude_file_flag_supported = status.success? && output.match?(/--file\b/)
    rescue Errno::ENOENT
      @claude_file_flag_supported = false
    end
  end

  SIDECAR_ENV_FORWARD = AgentProviders::Base::SIDECAR_ENV_FORWARD

  def perform(chat_session_id, user_message_id)
    @chat = ChatSession.includes(
      :user,
      :attached_repositories,
      :attached_jobs,
      :attached_repository_documents,
      attached_epics: [ :repository, { jobs: :repository } ]
    ).find(chat_session_id)
    @user_message = @chat.messages.find(user_message_id)
    @turn_started_at = Time.current
    @stop_request_cutoff_at = @user_message.created_at || @turn_started_at
    @cancelled = false

    clear_stale_stop_request!
    @chat.clear_suggested_next_step!
    return if stop_requested?
    @current_assistant_content = []

    provider = chat_provider

    if provider.credentials_missing?
      create_message!("system", text: provider.credentials_missing_message)
      touch_chat!
      return
    end

    workspace_path = ensure_workspace!
    parent_session_id = resume_session_id_for(provider)
    attachment_context = attachment_context_for(workspace_path)
    return if stop_requested?

    @chat.broadcast_controls if provider.provider == "codex"

    result = with_chat_mcp_config do |mcp_config|
      with_git_askpass_env do |agent_env|
        provider_with_turn_context(provider, attachment_context, agent_env).invoke(
          workspace_path: workspace_path,
          prompt: prompt_for(parent_session_id, user_text: attachment_context.fetch(:user_text)),
          log_sink: method(:record_agent_event),
          mcp_config: mcp_config,
          resume_session_id: parent_session_id,
          stop_requested: method(:stop_requested?),
          process_started: ->(_process) { @chat.broadcast_controls }
        )
      end
    end

    flush_current_assistant_content!
    capture_session!(provider, result) if result
    @chat.record_turn_usage!(result) if result
    update_coding_checkout_uncommitted_state!
    touch_chat!
    stop_requested?
    if result&.is_error
      create_terminal_failure_message!(result: result, provider: provider) unless @cancelled
    else
      create_terminal_completion_message! unless @cancelled
    end
  rescue StandardError => e
    stop_requested? || create_terminal_failure_message!(exception: e)
    touch_chat! if @chat
    raise
  ensure
    finalize_turn!
  end

  private

  def clear_stale_stop_request!
    @chat.reload
    return unless @chat.stop_requested_at && @chat.stop_requested_at <= @stop_request_cutoff_at

    @chat.update!(stop_requested_at: nil)
  end

  def clear_stop_request_and_broadcast_controls!
    return unless @chat

    @chat.reload
    @chat.update!(stop_requested_at: nil) if @chat.stop_requested_at?
    @chat.broadcast_controls
  end

  def finalize_turn!
    return unless @chat

    clear_stop_request_and_broadcast_controls!
    ChatQueuedMessagePromoter.deliver_one_if_idle!(@chat)
  end

  def ensure_workspace!
    workspace_path = ChatWorkspace.ensure_root!(@chat)
    if coding_mode_active?
      ensure_coding_checkout!
    else
      refresh_attached_repository_checkouts!(workspace_path)
    end
    workspace_path
  end

  def chat_provider
    @chat.pin_chat_provider!(broadcast: false) if @chat.chat_provider.blank? && @chat.messages.exists?
    ChatProviders.for(@chat.effective_chat_provider).new(chat: @chat, runner: self.class.agent_runner)
  end

  def provider_with_turn_context(provider, attachment_context, agent_env)
    provider.class.new(
      chat: @chat,
      runner: self.class.agent_runner,
      image_paths: attachment_context.fetch(:image_paths),
      file_paths: attachment_context.fetch(:file_paths),
      env: agent_env
    )
  end

  def resume_session_id_for(_provider)
    @chat.claude_session&.session_id
  end

  def refresh_attached_repository_checkouts!(workspace_path)
    repositories_path = Pathname(workspace_path).join("repositories")

    @chat.attached_repositories.each do |repository|
      next unless repositories_path.join(repository.owner, repository.name, ".git").directory?

      ChatWorkspace.attach_repository!(@chat, repository)
    rescue => e
      Rails.logger.warn("[ChatTurnJob] checkout refresh failed for chat ##{@chat.id} #{repository.slug}: #{e.class}: #{e.message}")
    end
  end

  def prompt_for(parent_session_id, user_text:)
    snapshot = AgentEnvironmentSnapshot.for_chat(repository: @chat.repository, chat_session: @chat)
    return proposal_outcome_prompt(snapshot: snapshot, user_text: user_text) if proposal_outcome_message?

    walkthrough_text = walkthrough_orientation(user_note: user_text)
    if walkthrough_text
      return [ snapshot, system_guidance(parent_session_id), (chat_history_fallback if parent_session_id.present?), walkthrough_text ]
        .compact.join("\n\n---\n\n")
    end

    if parent_session_id.present?
      elaboration_guidance = Prompts::ChatSystem.new(repository: @chat.repository, chat_session: @chat).elaboration_guidance
      return [ snapshot, elaboration_guidance.presence, coding_mode_guidance, chat_history_fallback, user_text ].compact.join("\n\n---\n\n")
    end

    [ Prompts::ChatSystem.new(repository: @chat.repository, chat_session: @chat).to_s, coding_mode_guidance, user_text ].compact.join("\n\n")
  end

  # A walkthrough-video message triggers the FIRST-CLASS handoff: rather than
  # dumping the analysis in as a fake user message, orient the agent to pull it
  # with its tools (get_walkthrough_analysis / read_walkthrough_frame) and work
  # autonomously toward an Epic. Returns nil for a normal message. If the row
  # vanished, fall through to a normal turn on whatever note was typed.
  def walkthrough_orientation(user_note:)
    # Labs flag off → historic walkthrough messages read as plain notes; the
    # agent is not oriented toward tools it can no longer see.
    return nil unless Feature.video_walkthroughs_enabled?
    return nil unless @user_message.content.is_a?(Hash)

    walkthrough_id = @user_message.content["video_walkthrough_id"]
    return nil if walkthrough_id.blank?

    walkthrough = ChatVideoWalkthrough.find_by(id: walkthrough_id)
    return nil unless walkthrough

    Prompts::VideoWalkthroughContext.new(walkthrough: walkthrough, user_note: user_note).to_s
  end

  # Full system prompt for a fresh session; the compact elaboration guidance when
  # resuming (the resumed session already carries the full system context).
  def system_guidance(parent_session_id)
    chat_system = Prompts::ChatSystem.new(repository: @chat.repository, chat_session: @chat)
    base = parent_session_id.present? ? chat_system.elaboration_guidance.presence : chat_system.to_s
    coding = coding_mode_guidance
    [ base, coding ].compact.join("\n\n")
  end

  def coding_mode_active?
    Feature.coding_mode_enabled? && @chat.coding? && @chat.repository.present?
  end

  def ensure_coding_checkout!
    ChatWorkspace.ensure_coding_checkout!(@chat, @chat.repository)
  rescue StandardError => e
    @coding_checkout_setup_error = "#{e.class}: #{e.message}"
    Rails.logger.warn("[ChatTurnJob] coding checkout setup failed for chat ##{@chat.id}: #{e.class}: #{e.message}")
  end

  def update_coding_checkout_uncommitted_state!
    return unless coding_mode_active?
    return unless @chat.coding_checkout_branch.present?

    path = ChatWorkspace.repo_path_for(@chat, @chat.repository)
    uncommitted = ChatWorkspace.uncommitted_changes?(path)
    return if @chat.coding_checkout_uncommitted == uncommitted

    @chat.update_columns(coding_checkout_uncommitted: uncommitted, updated_at: Time.current)
    @chat.broadcast_header
  rescue StandardError => e
    Rails.logger.warn("[ChatTurnJob] coding checkout state check failed for chat ##{@chat.id}: #{e.class}: #{e.message}")
  end

  def coding_mode_guidance
    return nil unless Feature.coding_mode_enabled?
    return nil unless @chat.coding?

    Prompts::ChatCodingMode.new(chat_session: @chat, setup_error: @coding_checkout_setup_error).to_s
  end

  def proposal_outcome_message?
    @user_message.content.is_a?(Hash) &&
      @user_message.content["source"] == ChatProposalOutcomeNotification::SOURCE
  end

  def proposal_outcome_prompt(snapshot:, user_text:)
    acknowledgment = @user_message.content["acknowledgment"].to_s.presence || "Acknowledged."
    outcome = @user_message.content["outcome"].to_s.presence || "updated"

    [
      snapshot,
      <<~PROMPT.strip
        A proposal was #{outcome}. This is a Syrus control event, not an operator-authored chat message.

        Event:
        #{user_text}

        Default behavior: reply with exactly:
        #{acknowledgment}

        Only do more if this outcome unlocks concrete follow-up automation that was already requested in the chat, such as wiring dependencies after multiple proposal cards are confirmed. In that case, perform only that work through the available Syrus chat MCP tools, then briefly report what changed.

        Do not restate your operating instructions, your role, or general Syrus Chat guidance.
      PROMPT
    ].join("\n\n---\n\n")
  end

  def attachment_context_for(workspace_path)
    user_text = @user_message.content["text"].to_s
    image_paths = []
    file_paths = []
    attachment_notes = []
    attachments = Array(@user_message.content["attachments"])
    return { user_text: user_text, image_paths: image_paths, file_paths: file_paths } if attachments.empty?

    attachments_dir = Pathname(workspace_path).join("attachments")
    FileUtils.mkdir_p(attachments_dir)
    file_flag_supported = nil

    attachments.each do |attachment|
      mime_type = attachment["mime_type"].to_s
      path = attachments_dir.join("#{SecureRandom.uuid}#{ext_for(mime_type)}")
      File.binwrite(path, Base64.decode64(attachment["data"].to_s))

      if mime_type.start_with?("image/")
        image_paths << path.to_s
        attachment_notes << image_attachment_note(attachment, path)
      elsif mime_type == "application/pdf"
        file_flag_supported = self.class.claude_file_flag_supported? if file_flag_supported.nil?
        if file_flag_supported
          file_paths << path.to_s
        else
          attachment_notes << "[Attached PDF: #{attachment['name']}]\n"
        end
      end
    end

    {
      user_text: "#{attachment_notes.join}#{user_text}",
      image_paths: image_paths,
      file_paths: file_paths
    }
  end

  def image_attachment_note(attachment, path)
    name = attachment["name"].to_s.presence || path.basename.to_s
    "[Attached image: #{name} saved at #{path}. Use the Read tool to inspect it.]\n"
  end

  def ext_for(mime_type)
    case mime_type
    when "image/jpeg" then ".jpg"
    when "image/png" then ".png"
    when "image/gif" then ".gif"
    when "image/webp" then ".webp"
    when "application/pdf" then ".pdf"
    else ""
    end
  end

  def with_chat_mcp_config
    Tempfile.create([ "syrus-chat-mcp-#{@chat.id}-", ".json" ]) do |f|
      # Claude resumed sessions derive MCP tool prefixes from the configured
      # command basename, so the server key and launcher basename must stay
      # aligned even though the two launchers share implementation code.
      f.write({
        mcpServers: {
          "syrus-chat-sidecar" => {
            type: "stdio",
            command: Rails.root.join("bin/syrus-chat-sidecar").to_s,
            env: sidecar_env(tool_tier: "essential", server_name: "syrus-chat-sidecar"),
            alwaysLoad: true
          },
          "syrus-chat-deferred-sidecar" => {
            type: "stdio",
            command: Rails.root.join("bin/syrus-chat-deferred-sidecar").to_s,
            env: sidecar_env(tool_tier: "deferred", server_name: "syrus-chat-deferred-sidecar"),
            alwaysLoad: false
          }
        }
      }.to_json)
      f.flush
      yield f.path
    end
  end

  def sidecar_env(tool_tier:, server_name:)
    env = ENV.slice(*SIDECAR_ENV_FORWARD).compact
    if env["BUNDLE_PATH"].present?
      env["GEM_HOME"] ||= env["BUNDLE_PATH"]
      env["GEM_PATH"] ||= env["BUNDLE_PATH"]
    end

    env.merge(
      "SYRUS_CHAT_SESSION_ID" => @chat.id.to_s,
      "SYRUS_CHAT_CURRENT_MESSAGE_ID" => @user_message.id.to_s,
      "SYRUS_CHAT_MCP_TOOL_TIER" => tool_tier,
      "SYRUS_CHAT_MCP_SERVER_NAME" => server_name
    )
  end

  def with_git_askpass_env
    env = { "GIT_TERMINAL_PROMPT" => "0" }
    repository = @chat.repository
    return yield env unless repository

    askpass_path = nil
    Tempfile.create([ "git-askpass-#{SecureRandom.uuid}-", ".sh" ], Dir.tmpdir) do |file|
      askpass_path = file.path
      token = GithubClient.for(repository: repository, user: @chat.user).access_token
      file.write("#!/bin/sh\necho \"x-access-token:#{token}\"\n")
      file.flush
      File.chmod(0o700, askpass_path)
      yield env.merge("GIT_ASKPASS" => askpass_path)
    ensure
      FileUtils.rm_f(askpass_path) if askpass_path
    end
  end

  def record_agent_event(chunk, kind: nil, tool_name: nil, tool_input: nil,
                         tool_result_content: nil, tool_result_error: nil,
                         tool_use_id: nil, thinking: nil, signature: nil,
                         mcp_servers: nil, **)
    case kind.to_s
    when "thinking"
      block = { "type" => "thinking", "thinking" => thinking.to_s }
      block["signature"] = signature if signature.present?
      @current_assistant_content << block
    when "assistant_text"
      @current_assistant_content << { "type" => "text", "text" => chunk.to_s }
    when "tool_call"
      return if tool_name.blank?

      flush_current_assistant_content!
      McpToolUsageRecorder.record_chat_tool_call(
        chat_session: @chat,
        tool_name: tool_name,
        tool_use_id: tool_use_id,
        tool_input: tool_input,
        provider: @chat.effective_chat_provider
      ) if mcp_tool_name?(tool_name)
      @chat.messages.create!(
        role: "tool_use",
        tool_name: tool_name,
        tool_use_id: tool_use_id,
        content: {
          "type" => "tool_use",
          "id" => tool_use_id.to_s,
          "name" => tool_name.to_s,
          "input" => tool_input || {}
        }
      )
    when "tool_result"
      return if tool_name.blank? && tool_use_id.blank? && tool_result_content.blank?

      flush_current_assistant_content!
      if mcp_tool_name?(tool_name) || mcp_tool_result_id?(tool_use_id)
        McpToolUsageRecorder.record_chat_tool_result(
          chat_session: @chat,
          tool_name: tool_name,
          tool_use_id: tool_use_id,
          content: tool_result_content,
          error: tool_result_error == true,
          provider: @chat.effective_chat_provider
        )
      end
      anchor_pending_action_to_tool_call!(tool_use_id, tool_result_content) unless tool_result_error == true
      @chat.messages.create!(
        role: "tool_result",
        tool_name: tool_name,
        tool_use_id: tool_use_id,
        content: {
          "type" => "tool_result",
          "tool_use_id" => tool_use_id.to_s,
          "content" => tool_result_content,
          "is_error" => tool_result_error == true
        }
      )
    else
      flush_current_assistant_content!
      return if mcp_servers.present? &&
                mcp_servers.all? { |server| mcp_pending?(server["status"].to_s) }

      create_message!("system", system_content_for(chunk, mcp_servers: mcp_servers))
    end
  end

  def mcp_tool_name?(tool_name)
    name = tool_name.to_s
    name.start_with?("mcp__") || name.include?(".")
  end

  def mcp_tool_result_id?(tool_use_id)
    tool_use_id.present? && McpToolUsage.where(chat_session: @chat, tool_use_id: tool_use_id.to_s).exists?
  end

  def anchor_pending_action_to_tool_call!(tool_use_id, tool_result_content)
    pending_action_id = ChatPendingAction.pending_action_id_from_tool_result(tool_result_content)
    ChatPendingAction.anchor_to_tool_call!(
      chat_session: @chat,
      pending_action_id: pending_action_id,
      tool_use_id: tool_use_id
    )
  end

  def flush_current_assistant_content!
    return if @current_assistant_content.nil? || @current_assistant_content.empty?

    blocks = @current_assistant_content.dup
    @current_assistant_content = []
    @chat.messages.create!(role: "assistant", content: blocks)
  end

  def system_content_for(chunk, mcp_servers:)
    content = { text: chunk.to_s }
    return content unless mcp_servers.present?

    stderr = mcp_stderr_for(mcp_servers)
    content = content.merge(mcp_health: mcp_health_for(mcp_servers))
    return content if stderr.blank?

    content.merge(
      text: "#{chunk}\n\n[mcp_sidecar_stderr]\n#{stderr}",
      mcp_sidecar_stderr: stderr
    )
  end

  def mcp_health_for(servers)
    Array(servers).filter_map do |server|
      name = server["name"].to_s
      status = server["status"].to_s.presence || "unknown"
      next if name.blank?

      tool_names = mcp_tool_names_for(name)
      {
        "name" => name,
        "status" => status,
        "available_tools" => mcp_available?(status) ? tool_names : [],
        "pending_tools" => mcp_pending?(status) ? tool_names : [],
        "unavailable_tools" => mcp_unavailable?(status) ? tool_names : []
      }
    end
  end

  def mcp_tool_names_for(name)
    return SyrusChatMcp::Sidecar.tool_names(@chat) if name == "syrus-chat-sidecar"
    return SyrusChatMcp::DeferredSidecar.tool_names(@chat) if name == "syrus-chat-deferred-sidecar"

    []
  end

  def mcp_stderr_for(servers)
    Array(servers).filter_map do |server|
      status = server["status"].to_s
      next unless mcp_unavailable?(status)

      name = server["name"].to_s
      next if name.blank?

      stderr = McpSidecarLog.tail_chat(
        @chat.id,
        message_id: @user_message.id,
        server_name: name
      )
      next if stderr.blank?

      "#{name}:\n#{stderr}"
    end.join("\n\n")
  end

  def mcp_available?(status)
    status.in?(%w[connected running ready])
  end

  def mcp_pending?(status)
    status == "pending"
  end

  def mcp_unavailable?(status)
    !mcp_available?(status) && !mcp_pending?(status)
  end

  def stop_requested?
    @chat.reload
    return false unless @chat.stop_requested_at && @chat.stop_requested_at > @stop_request_cutoff_at

    unless @cancelled
      @cancelled = true
      flush_current_assistant_content!
      create_message!("system", text: "Cancelled by operator.")
    end
    true
  end

  def create_terminal_failure_message!(exception: nil, result: nil, provider: nil)
    return unless @chat && @user_message

    @chat.reload
    return unless @chat.turn_in_flight?

    create_message!("system", terminal_failure_content(exception: exception, result: result, provider: provider))
  end

  def create_terminal_completion_message!
    return unless @chat && @user_message

    @chat.reload
    return unless @chat.turn_in_flight?

    create_message!("system", text: "Agent turn completed.")
  end

  def create_message!(role, content)
    @chat.messages.create!(role: role, content: content.stringify_keys)
  end

  def terminal_failure_content(exception:, result:, provider:)
    detail = result&.final_text.to_s.presence ||
      exception_detail(exception).presence ||
      "Agent turn failed."

    provider_name = provider&.provider.to_s.presence || @chat.effective_chat_provider.to_s.presence
    model = ProviderUsageLimit.extract_model(detail, fallback: @chat.chat_model)

    if result&.outcome.to_s == ProviderUsageLimit::OUTCOME || ProviderUsageLimit.detect?(detail)
      message = ProviderUsageLimit.detail(provider: provider_name, model: model, message: detail)
      return {
        text: message,
        provider_error: {
          kind: ProviderUsageLimit::OUTCOME,
          provider: provider_name,
          model: model,
          halted: true,
          detail: detail
        }.compact
      }
    end

    {
      text: detail == "Agent turn failed." ? detail : "Agent turn failed: #{detail}",
      provider_error: {
        kind: result&.outcome.to_s.presence || exception&.class&.name,
        provider: provider_name,
        model: model,
        halted: false,
        detail: detail
      }.compact
    }
  end

  def exception_detail(exception)
    return nil unless exception

    "#{exception.class}: #{exception.message}"
  end

  def capture_session!(provider, result)
    capture = provider.session_capture(result)
    return unless capture

    create_message!("system", text: capture.missing_message) if capture.missing_message.present?

    attrs = {
      provider: capture.provider,
      session_id: capture.session_id,
      transcript_jsonl: capture.transcript_jsonl
    }

    session = if @chat.claude_session
      @chat.claude_session.tap { |existing| existing.update!(attrs) }
    else
      @chat.create_claude_session!(attrs)
    end

    persist_optional_session_metadata(session, capture)
  end

  def persist_optional_session_metadata(session, capture)
    return unless claude_session_has_attribute?(:normalized_messages)

    session.update!(normalized_messages: capture.normalized_messages)
  rescue StandardError => e
    Rails.logger.warn(
      "[chat_session] optional metadata capture failed " \
      "chat_id=#{@chat.id} session_id=#{capture.session_id}: #{e.class}: #{e.message}"
    )
  end

  def claude_session_has_attribute?(attribute)
    ClaudeSession.attribute_names.include?(attribute.to_s)
  end

  def touch_chat!
    @chat.update!(last_message_at: Time.current)
  end
end
