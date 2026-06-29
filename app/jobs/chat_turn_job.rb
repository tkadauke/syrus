require "base64"
require "fileutils"
require "open3"
require "securerandom"
require "tempfile"
require "tmpdir"

class ChatTurnJob < ApplicationJob
  CONCURRENCY_GROUP = "repository_chat"

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
    @cancelled = false

    @chat.update!(stop_requested_at: nil)

    provider = chat_provider

    if provider.credentials_missing?
      create_message!("system", text: provider.credentials_missing_message)
      touch_chat!
      return
    end

    workspace_path = ensure_workspace!
    parent_session_id = @chat.claude_session&.session_id
    attachment_context = attachment_context_for(workspace_path)

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

    capture_session!(provider, result) if result
    @chat.record_turn_usage!(result) if result
    touch_chat!
    deliver_next_queued_message!
  ensure
    clear_stop_request_and_broadcast_controls!
  end

  private

  def clear_stop_request_and_broadcast_controls!
    return unless @chat

    @chat.reload
    @chat.update!(stop_requested_at: nil) if @chat.stop_requested_at?
    @chat.broadcast_controls
  end

  def ensure_workspace!
    workspace_path = ChatWorkspace.ensure_root!(@chat)
    refresh_attached_repository_checkouts!(workspace_path)
    workspace_path
  end

  def chat_provider
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
    return [ snapshot, user_text ].join("\n\n---\n\n") if parent_session_id.present?

    [ Prompts::ChatSystem.new(repository: @chat.repository, chat_session: @chat).to_s, user_text ].join("\n\n")
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
    ENV.slice(*SIDECAR_ENV_FORWARD).compact.merge(
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
                         tool_use_id: nil, mcp_servers: nil, **)
    case kind.to_s
    when "tool_call"
      # Persist the structured tool invocation. Abbreviation is the
      # presentation layer's job; storing the raw input keeps the data
      # tier honest and lets the view evolve without DB churn.
      @chat.messages.create!(
        role: "tool_use",
        tool_name: tool_name,
        content: { "input" => tool_input || {} }
      )
    when "tool_result"
      @chat.messages.create!(
        role: "tool_result",
        tool_name: tool_name,
        content: {
          "result" => tool_result_content,
          "is_error" => tool_result_error,
          "tool_use_id" => tool_use_id
        }.compact
      )
    when "assistant_text"
      create_message!("assistant", text: chunk.to_s)
    else
      return if mcp_servers.present? &&
                mcp_servers.all? { |server| mcp_pending?(server["status"].to_s) }

      create_message!("system", system_content_for(chunk, mcp_servers: mcp_servers))
    end
  end

  def system_content_for(chunk, mcp_servers:)
    content = { text: chunk.to_s }
    return content unless mcp_servers.present?

    content.merge(mcp_health: mcp_health_for(mcp_servers))
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
    return false unless @chat.stop_requested_at && @chat.stop_requested_at > @turn_started_at

    unless @cancelled
      @cancelled = true
      create_message!("system", text: "Cancelled by operator.")
    end
    true
  end

  def create_message!(role, content)
    @chat.messages.create!(role: role, content: content.stringify_keys)
  end

  def capture_session!(provider, result)
    capture = provider.session_capture(result)
    return unless capture

    attrs = {
      provider: capture.provider,
      session_id: capture.session_id,
      transcript_jsonl: capture.transcript_jsonl
    }
    if claude_session_has_attribute?(:raw_provider_transcript)
      attrs[:raw_provider_transcript] = capture.raw_provider_transcript
    end
    attrs[:normalized_messages] = capture.normalized_messages if claude_session_has_attribute?(:normalized_messages)

    if @chat.claude_session
      @chat.claude_session.update!(attrs)
    else
      @chat.create_claude_session!(attrs)
    end
  end

  def claude_session_has_attribute?(attribute)
    ClaudeSession.attribute_names.include?(attribute.to_s)
  end

  def touch_chat!
    @chat.update!(last_message_at: Time.current)
  end

  def deliver_next_queued_message!
    user_message = nil

    ApplicationRecord.transaction do
      locked_chat = ChatSession.lock.find(@chat.id)
      queued_message = locked_chat.queued_messages.first
      if queued_message
        user_message = locked_chat.messages.create!(role: "user", content: queued_message.content)
        queued_message.update!(delivered_at: Time.current)
        locked_chat.update!(
          last_message_at: Time.current,
          title: locked_chat.title.presence
        )
      end
    end
    return false unless user_message

    ChatTurnJob.perform_later(@chat.id, user_message.id)
    true
  end
end
