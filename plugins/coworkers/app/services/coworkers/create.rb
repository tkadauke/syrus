class Coworkers::Create
  BranchExists = Class.new(StandardError)
  InvalidRemote = Class.new(ArgumentError)
  KickoffEnqueueFailed = Class.new(ActiveJob::EnqueueError)

  DEFAULT_GRANTS = {
    "chat.message_owner" => "auto",
    "workspace.files" => "auto",
    "workspace.shell" => "auto",
    "chats.read_shared" => "auto",
    "coworker.message" => "confirm",
    "coworker.spawn_chat" => "confirm",
    "schedule.manage_self" => "confirm",
    "syrus.read_jobs" => "auto",
    "syrus.propose_job" => "confirm"
  }.freeze

  PLACEHOLDER_SOUL = <<~MARKDOWN.freeze
    role: not set up yet

    You have not been set up yet. Interview your owner about your name, role,
    personality, how you should work, and what you should never do. Then write
    what you learn into SOUL.md, USER.md, and AGENTS.md.
  MARKDOWN
  AGENTS = <<~MARKDOWN.freeze
    # Operating rules

    Keep SOUL.md, USER.md, and memory/ current as you work with your owner.
    Treat this branch as your persistent home and do not push outside coworkers/.
  MARKDOWN
  USER = "# Owner\n\nLearn about your owner during your first conversation.\n".freeze
  KICKOFF = "Your identity has not been set up yet. Interview your owner now and update your workspace identity files with the answers.".freeze

  def self.call(...) = new(...).call

  def initialize(owner:, name:, handle:, workspace_repo:, about: nil, color_key: nil, avatar_key: nil,
                 chat_provider: nil, chat_model: nil, chat_effort: nil, avatar: nil, grants: nil, remote_workspace: nil)
    @owner = owner
    @name = name
    @handle = HandleRegistry.normalize(handle)
    @workspace_repo = workspace_repo
    @about = about.to_s.strip.presence
    @avatar = avatar
    @grants = grants
    @attributes = { color_key: color_key, avatar_key: avatar_key, chat_provider: chat_provider,
                    chat_model: chat_model, chat_effort: chat_effort }.compact
    remote_owner, remote_name = parse_remote(workspace_repo)
    @remote = remote_workspace || Coworkers::RemoteWorkspace.new(owner: remote_owner, name: remote_name, user: owner)
  end

  def call
    validate_handle!
    raise BranchExists, "#{branch} already exists" if @remote.branch_exists?(branch)
    @remote.test_push_access!

    pushed = false
    coworker = begin
      @remote.seed!(branch: branch, files: seed_files, identity: Coworkers::GitIdentity.new(name: @name, handle: @handle))
      pushed = true
      ApplicationRecord.transaction do
        coworker = create_records!(register_repository!)
        create_kickoff!(coworker) unless @about
        coworker
      end
    rescue StandardError
      @remote.delete!(branch) if pushed
      raise
    end

    coworker
  end

  private

  def branch = "coworkers/#{@handle}"

  def validate_handle!
    candidate = Handle.new(handle: @handle)
    raise ActiveRecord::RecordInvalid, candidate unless candidate.valid?
  end

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
    chat = ChatSession.create!(user: @owner, repository: repository, title: @name, chat_provider: @attributes[:chat_provider])
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    coworker
  end

  def create_kickoff!(coworker)
    chat = coworker.coworker_chats.find_by!(role: "main").chat_session
    message = chat.messages.create!(role: "system", content: { "text" => KICKOFF }, skip_turn_trigger: false)
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
    return PLACEHOLDER_SOUL unless @about
    "role: #{role_summary}\n\n#{@about}\n"
  end

  def seed_files
    {
      "SOUL.md" => soul,
      "AGENTS.md" => AGENTS,
      "USER.md" => USER,
      "memory/.gitkeep" => "",
      ".gitattributes" => "memory/** merge=union\n"
    }
  end

  def selected_grants
    return DEFAULT_GRANTS unless @grants

    DEFAULT_GRANTS.slice(*Array(@grants).map(&:to_s))
  end

  def parse_remote(value)
    match = value.to_s.strip.match(%r{\A(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?/?\z}i)
    raise InvalidRemote, "workspace_repo must be a GitHub repository URL" unless match
    [ match[1], match[2] ]
  end
end
