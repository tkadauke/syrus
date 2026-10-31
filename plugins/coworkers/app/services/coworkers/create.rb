class Coworkers::Create
  BranchExists = Class.new(StandardError)
  InvalidRemote = Class.new(ArgumentError)
  KickoffEnqueueFailed = Class.new(ActiveJob::EnqueueError)
  class CreationFailed < StandardError
    attr_reader :outcome, :attempt_id
    def initialize(outcome:, attempt:, cause:)
      @outcome = outcome
      @attempt_id = attempt.id
      super("coworker creation failed; remote cleanup #{outcome == :fully_rolled_back ? 'completed' : 'is pending'}: #{GitRunner.redact(cause.message)}")
    end
  end

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

    During every turn, keep SOUL.md, USER.md, AGENTS.md, and memory/ current
    without asking permission. Before replying, save any durable facts,
    preferences, decisions, commitments, deadlines, opinions, lessons, or
    project context that came up. Never store credentials, tokens, or secrets,
    and only report an update as saved after its workspace tool succeeds.

    Put events and decisions in `memory/daily/YYYY-MM-DD.md`, people facts in
    `memory/people/<handle>.md`, repository context in
    `memory/repos/<owner>__<name>.md`, and opinions, experiences, reflections,
    and commitments in the matching `memory/banks/*` file. Put owner
    preferences in USER.md and your identity and rules in SOUL.md and AGENTS.md.
    Keep entries short and factual. Append one entry per event rather than
    rewriting earlier entries, and link people using their `@handle`.

    Read older daily files and the opinion, experience, reflection, and
    commitment banks on demand when they are relevant. Read at most 64 KiB
    from any one memory file and include
    `[truncated at the coworker memory cap]` when more content exists.

    Treat this branch as your persistent home and do not push outside coworkers/.
  MARKDOWN

  def self.call(...) = new(...).call

  def initialize(owner:, name:, handle:, workspace_repo:, about: nil, accent_hex: nil, avatar_key: nil,
                 chat_provider: nil, chat_model: nil, chat_effort: nil, avatar: nil, grants: nil, remote_workspace: nil,
                 idempotency_key: nil)
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
    @idempotency_key = idempotency_key.presence || SecureRandom.uuid
  end

  def call
    prior = Coworkers::ProvisioningAttempt.find_by(owner_user: @owner, idempotency_key: @idempotency_key)
    return prior.coworker if prior&.state == "completed" && prior.coworker
    raise CreationFailed.new(outcome: :cleanup_pending, attempt: prior, cause: StandardError.new("an earlier delivery is still being reconciled")) if prior

    checked = Coworkers::CreatePreflight.new(
      owner: @owner, name: @name, handle: @handle, workspace_repo: @workspace_repo,
      grants: @grants, remote_workspace: @remote_workspace, **@attributes
    ).call
    @handle = checked.handle
    @remote = checked.remote
    @selected_grants = checked.grants
    @attempt = Coworkers::ProvisioningAttempt.create_or_find_by!(owner_user: @owner, idempotency_key: @idempotency_key) do |attempt|
      attempt.remote_owner = @remote.repository.owner
      attempt.remote_name = @remote.repository.name
      attempt.handle = @handle
      attempt.branch = branch
    end
    unless @attempt.previously_new_record?
      return @attempt.coworker if @attempt.state == "completed" && @attempt.coworker
      raise CreationFailed.new(outcome: :cleanup_pending, attempt: @attempt, cause: StandardError.new("an earlier delivery is still being reconciled"))
    end

    coworker = begin
      sha = @remote.seed!(branch: branch, files: seed_files, identity: Coworkers::GitIdentity.new(name: @name, handle: @handle)) do |expected_sha|
        # Persist the proof before the network push so a process death immediately
        # after the remote accepts it remains safely reconcilable.
        @attempt.update!(expected_seeded_commit: expected_sha)
      end
      @attempt.update!(expected_seeded_commit: sha, seeded_at: Time.current)
      ApplicationRecord.transaction do
        coworker = create_records!(register_repository!)
        create_kickoff!(coworker)
        @attempt.update!(state: "completed", coworker: coworker, completed_at: Time.current, last_error: nil)
        coworker
      end
    rescue StandardError => creation_error
      compensate!(creation_error)
    end

    coworker
  end

  private

  def compensate!(creation_error)
    unless @attempt.expected_seeded_commit.present?
      @attempt.update!(state: "cleaned", cleaned_at: Time.current, last_error: redacted_error(creation_error))
      raise CreationFailed.new(outcome: :fully_rolled_back, attempt: @attempt, cause: creation_error)
    end

    @attempt.update!(state: "cleanup_pending", cleanup_started_at: Time.current, last_error: redacted_error(creation_error))
    begin
      Coworkers::ProvisioningCleanup.call(@attempt, remote_workspace: @remote)
    rescue StandardError => cleanup_error
      Rails.logger.error("[Coworkers::Create] durable cleanup pending attempt_id=#{@attempt.id} error=#{redacted_error(cleanup_error)}")
      Coworkers::ProvisioningCleanupJob.perform_later(@attempt.id)
    end
    outcome = @attempt.reload.state == "cleaned" ? :fully_rolled_back : :cleanup_pending
    raise CreationFailed.new(outcome: outcome, attempt: @attempt, cause: creation_error)
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
    selected_grants.each { |grant| coworker.grants.create!(grant) }
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
    return configured_identity_kickoff if @about

    "You are #{@name}, and your owner is #{@owner.display_name}. Your identity has not been set up yet. " \
      "Interview your owner about your role, personality, working preferences, and boundaries, then update your workspace identity files with the answers. " \
      "Keep your identity and memory files current during every turn without asking permission, and save durable details before your final reply."
  end

  def configured_identity_kickoff
    "You are #{@name}, and your owner is #{@owner.display_name}. Your owner has already described your identity in SOUL.md. " \
      "Read your workspace identity files, then briefly greet your owner in your own voice and explain in one or two sentences how you understand your role. " \
      "Ask a small number of concrete questions about anything important that is unclear or missing, such as preferences, boundaries, how and when to contact your owner, or which repositories and people matter. " \
      "Do not conduct a long interview or claim to have done work you have not done. Keep your identity and memory files current during every turn without asking permission, and save durable details before your final reply. " \
      "If nothing is unclear, say hello and ask what you should work on first."
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
