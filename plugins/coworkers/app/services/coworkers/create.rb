class Coworkers::Create
  BranchExists = Class.new(StandardError)
  InvalidRemote = Class.new(ArgumentError)
  KickoffEnqueueFailed = Class.new(ActiveJob::EnqueueError)

  DEFAULT_GRANTS = {
    "chat.message_owner" => "confirm",
    "workspace.files" => "auto",
    "workspace.shell" => "auto",
    "chats.read_shared" => "auto",
    "coworker.message" => "confirm",
    "coworker.spawn_chat" => "confirm",
    "schedule.manage_self" => "confirm",
    "syrus.read_jobs" => "auto",
    "syrus.propose_job" => "confirm"
  }.freeze

  AGENTS = <<~MARKDOWN.freeze
    # Operating rules

    Keep SOUL.md, USER.md, and memory/ current as you work with your owner.
    Keep daily files (`memory/daily/YYYY-MM-DD.md`), people files
    (`memory/people/<handle>.md`), and bank files (`memory/banks/*.md`)
    append-oriented. Add one entry per event rather than rewriting earlier
    entries, and link people using their `@handle`.

    Read older daily files and the opinion, experience, reflection, and
    commitment banks on demand when they are relevant. Read at most 64 KiB
    from any one memory file and include
    `[truncated at the coworker memory cap]` when more content exists.

    Treat this branch as your persistent home and do not push outside coworkers/.
  MARKDOWN

  def self.call(...) = new(...).call

  def initialize(owner:, name:, handle:, workspace_repo:, about: nil, accent_hex: nil, avatar_key: nil,
                 chat_provider: nil, chat_model: nil, chat_effort: nil, avatar: nil, grants: nil, remote_workspace: nil)
    @owner = owner
    @name = name
    @handle = HandleRegistry.normalize(handle)
    @workspace_repo = workspace_repo
    @about = about.to_s.strip.presence
    @avatar = avatar
    @grants = grants
    @attributes = { accent_hex: accent_hex, avatar_key: avatar_key, chat_provider: chat_provider,
                    chat_model: chat_model, chat_effort: chat_effort }.compact
    @remote_workspace = remote_workspace
  end

  def call
    checked = Coworkers::CreatePreflight.new(
      owner: @owner, name: @name, handle: @handle, workspace_repo: @workspace_repo,
      grants: @grants, remote_workspace: @remote_workspace, **@attributes
    ).call
    @handle = checked.handle
    @remote = checked.remote
    @selected_grants = checked.grants

    pushed = false
    coworker = begin
      @remote.seed!(branch: branch, files: seed_files, identity: Coworkers::GitIdentity.new(name: @name, handle: @handle))
      pushed = true
      ApplicationRecord.transaction do
        coworker = create_records!(register_repository!)
        create_kickoff!(coworker) unless @about
        coworker
      end
    rescue StandardError => creation_error
      rollback_seeded_branch(creation_error) if pushed
      raise
    end

    coworker
  end

  private

  def rollback_seeded_branch(creation_error)
    @remote.delete!(branch)
  rescue StandardError => cleanup_error
    Rails.logger.error(
      "[Coworkers::Create] coworker creation failed and seeded branch rollback also failed: " \
      "creation=#{redacted_error(creation_error)} cleanup=#{redacted_error(cleanup_error)}"
    )
  end

  def redacted_error(error)
    GitRunner.redact("#{error.class}: #{error.message}")
  end

  def branch = "coworkers/#{@handle}"

  def register_repository!
    existing = Repository.where("LOWER(owner) = ? AND LOWER(name) = ?", @remote.repository.owner.downcase, @remote.repository.name.downcase).first
    if existing
      grant_repository_access!(existing)
      return existing
    end

    Repository.create!(
      user: @owner, owner: @remote.repository.owner, name: @remote.repository.name,
      polling_enabled: false, auto_merge_enabled: false, external_pr_ingestion_enabled: false,
      main_branch_health_enabled: false, main_branch_repair_enabled: false,
      fork_auto_sync_enabled: false, pr_cost_footer_enabled: false
    )
  end

  def create_records!(repository)
    coworker = Coworkers::Coworker.create!({
      owner_user: @owner, name: @name, handle: @handle,
      workspace_repo: repository.remote_url, role_summary: role_summary
    }.merge(@attributes))
    selected_grants.each { |capability, policy| coworker.grants.create!(capability: capability, approval_policy: policy) }
    Coworkers::AvatarUpload.attach!(coworker, @avatar) if @avatar
    # Phase 1 attaches the workspace Repository directly to the main chat. The
    # per-chat coworker branch and merge-at-turn-end flow replaces this in Phase 3.
    chat = ChatSession.create!(user: @owner, repository: repository, title: @name, **coworker.chat_configuration)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    coworker
  end

  def create_kickoff!(coworker)
    chat = coworker.coworker_chats.find_by!(role: "main").chat_session
    message = chat.messages.create!(role: "system", content: { "text" => kickoff }, skip_turn_trigger: false)
    enqueued = ChatTurnJob.perform_later(chat.id, message.id)
    raise KickoffEnqueueFailed, "could not enqueue the coworker's kickoff turn" unless enqueued
  end

  def grant_repository_access!(repository)
    membership = repository.repository_memberships.find_or_initialize_by(user: @owner)
    membership.role = "write" unless membership.at_least?("write")
    membership.save! if membership.new_record? || membership.changed?
  end

  def role_summary = @about ? @about.lines.first.strip.delete_prefix("role:").strip : "not set up yet"

  def soul
    return "role: #{role_summary}\nname: #{@name}\n\n#{@about}\n" if @about

    <<~MARKDOWN
      role: not set up yet
      name: #{@name}

      Your name is #{@name}. Interview #{@owner.display_name}, your owner, about your role,
      personality, how you should work, and what you should never do. Then write
      what you learn into SOUL.md, USER.md, and AGENTS.md.
    MARKDOWN
  end

  def user = "# Owner\n\nYour owner is #{@owner.display_name}. Learn more about them during your first conversation.\n"

  def kickoff
    "You are #{@name}, and your owner is #{@owner.display_name}. Your identity has not been set up yet. " \
      "Interview your owner about your role, personality, working preferences, and boundaries, then update your workspace identity files with the answers."
  end

  def seed_files
    {
      "SOUL.md" => soul,
      "AGENTS.md" => AGENTS,
      "USER.md" => user,
      "memory/.gitkeep" => "",
      ".gitattributes" => "memory/** merge=union\n"
    }
  end

  def selected_grants
    @selected_grants
  end
end
