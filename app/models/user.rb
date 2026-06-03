class User < ApplicationRecord
  include AutoApproveModes

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :repositories, dependent: :destroy
  has_many :installations, dependent: :destroy
  has_many :epics, dependent: :destroy
  has_many :owned_epics, class_name: "Epic", foreign_key: :owner_id, dependent: :nullify, inverse_of: :owner
  has_many :jobs, dependent: :destroy
  has_many :dashboard_owned_epics, class_name: "Epic", foreign_key: :owner_user_id, dependent: :nullify, inverse_of: :owner_user
  has_many :owned_jobs, class_name: "Job", foreign_key: :owner_user_id, dependent: :nullify, inverse_of: :owner_user
  has_many :job_pins, dependent: :destroy
  has_many :pinned_jobs, through: :job_pins, source: :job
  has_many :smart_folders, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :chat_sessions
  has_many :documents, as: :attachable, dependent: :destroy
  has_many :chat_pending_actions, dependent: :destroy
  has_many :cron_templates, dependent: :destroy
  has_many :invitations, foreign_key: :invited_by_id, dependent: :nullify

  AGENT_PROVIDERS = %w[ claude codex ].freeze
  CODEX_AUTH_MODES = %w[ api_key chatgpt_login ].freeze
  CLEARABLE_CREDENTIALS = {
    "github_token" => "GitHub token",
    "claude_oauth_token" => "Claude OAuth token",
    "codex_api_key" => "Codex API key",
    "codex_auth_json" => "Codex ChatGPT auth.json",
    "telegram_chat_id" => "Telegram chat ID"
  }.freeze
  DASHBOARD_PREFERENCES_DEFAULTS = {
    "last_subject" => "epic",
    "last_view" => "list",
    "last_ownership_scope" => "team",
    "epics" => {
      "sort_column" => "updated_at",
      "sort_direction" => "desc",
      "visible_columns" => %w[epic state repository updated],
      "kanban_lanes" => %w[backlog ready in_progress done]
    },
    "jobs" => {
      "sort_column" => "created_at",
      "sort_direction" => "desc",
      "visible_columns" => %w[checkbox issue state repository latest workflows_count started],
      "kanban_lanes" => %w[queued running landing]
    },
    "workflows" => {
      "sort_column" => "started_at",
      "sort_direction" => "desc",
      "visible_columns" => %w[workflow job trigger state started finished agent],
      "kanban_lanes" => %w[queued running done]
    }
  }.freeze
  DASHBOARD_KANBAN_LANES = {
    "epics" => %w[backlog ready in_progress done],
    "jobs" => %w[blocked queued running succeeded landing failed],
    "workflows" => %w[queued running done succeeded failed]
  }.freeze
  DASHBOARD_REQUIRED_COLUMNS = {
    "epics" => %w[epic],
    "jobs" => %w[checkbox issue],
    "workflows" => %w[workflow job]
  }.freeze
  DASHBOARD_OPTIONAL_COLUMNS = {
    "epics" => %w[state owner repository updated created_at updated_at done_at archived_at],
    "jobs" => %w[
      state repository latest workflows_count started
      created_at updated_at started_at finished_at approved_at
      dependencies_overridden_at last_feedback_addressed_at
      last_seen_comment_at pr_mergeable_checked_at
    ],
    "workflows" => %w[
      trigger state started finished agent
      created_at updated_at started_at finished_at cleaned_up_at
    ]
  }.freeze
  DASHBOARD_SORT_COLUMNS = {
    "epic" => %w[title state repository updated_at],
    "job" => %w[title state repository created_at started_at],
    "workflow" => %w[title state started_at finished_at]
  }.freeze
  DASHBOARD_SORT_DEFAULTS = {
    "epic" => { "column" => "updated_at", "direction" => "desc" },
    "job" => { "column" => "created_at", "direction" => "desc" },
    "workflow" => { "column" => "started_at", "direction" => "desc" }
  }.freeze
  DASHBOARD_SORT_DIRECTIONS = %w[asc desc].freeze

  encrypts :claude_oauth_token
  encrypts :codex_api_key
  encrypts :codex_auth_json
  encrypts :github_token
  # `deterministic: true` so we can WHERE on the encrypted column
  # for the API auth lookup. Same plaintext always encrypts to the
  # same ciphertext under deterministic mode.
  encrypts :api_token, deterministic: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :github_handle, with: ->(h) { h.to_s.delete_prefix("@").strip.presence }
  normalizes :avatar_url, with: ->(value) { value.to_s.strip.presence }
  normalizes :first_name, :last_name, :profile_location, :profile_company, :profile_website,
             with: ->(value) { value.to_s.strip.presence }
  normalizes :profile_bio, with: ->(value) { value.to_s.strip.presence }

  # Per-user ceiling on `claude --max-turns`. The agent is given this
  # many tool-use turns before the run terminates with
  # error_max_turns. The previous global default of 50 was too low for
  # non-trivial issues — operators saw runs hit the cap mid-task. 200
  # covers the long tail; runaway loops still terminate eventually.
  #
  # Special-case: 0 means "no cap" (don't pass `--max-turns` at all).
  # AgentInvocation::DEFAULT_TIMEOUT_SECONDS still bounds the run, so a
  # genuinely-stuck agent doesn't run forever even with no turn cap.
  AGENT_MAX_TURNS_RANGE = (0..1000)

  validates :agent_max_turns,
            presence: true,
            numericality: { only_integer: true, in: AGENT_MAX_TURNS_RANGE }
  validates :agent_provider, presence: true, inclusion: { in: AGENT_PROVIDERS }
  validates :first_name, :last_name, length: { maximum: 80 }
  validates :github_handle, length: { maximum: 100 }
  validates :profile_bio, length: { maximum: 1000 }
  validates :avatar_url, length: { maximum: 500 }
  validates :codex_auth_mode, presence: true, inclusion: { in: CODEX_AUTH_MODES }
  validates :epic_reopen_window,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :profile_location, :profile_company, length: { maximum: 100 }
  validates :profile_website, length: { maximum: 255 }
  before_create :promote_first_user_to_admin

  def admin?
    admin
  end

  def display_name
    profile_name.presence || name.presence || email_address
  end

  def profile_name
    [ first_name, last_name ].compact_blank.join(" ").presence
  end

  def full_name
    profile_name.to_s
  end

  def team_display_name
    profile_name.presence || name.presence || (github_handle.present? ? "@#{github_handle}" : "User ##{id}")
  end

  def dashboard_preferences
    deep_merge_dashboard_preferences(
      DASHBOARD_PREFERENCES_DEFAULTS,
      normalized_dashboard_preferences(read_attribute(:dashboard_preferences))
    )
  end

  def dashboard_preferences=(value)
    write_attribute(:dashboard_preferences, normalized_dashboard_preferences(value).presence)
  end

  def update_dashboard_preferences!(subject: nil, view: nil, ownership_scope: nil, owner_user_id: nil)
    updated = dashboard_preferences
    updated["last_subject"] = normalize_dashboard_preference_subject(subject) if subject.present?
    updated["last_view"] = view.to_s if view.present?
    updated["last_ownership_scope"] = ownership_scope.to_s if ownership_scope.present?
    if owner_user_id.present?
      updated["last_owner_user_id"] = owner_user_id.to_s
    elsif ownership_scope.present? && ownership_scope.to_s != "user"
      updated.delete("last_owner_user_id")
    end

    update!(dashboard_preferences: updated) if updated != dashboard_preferences
  end

  def dashboard_sort(subject)
    subject_key = normalize_dashboard_preference_table(subject)
    normalized_subject = normalize_dashboard_preference_subject(subject)
    preferences = dashboard_preferences.fetch(subject_key)
    column = preferences["sort_column"].to_s.presence_in(DASHBOARD_SORT_COLUMNS.fetch(normalized_subject)) ||
             DASHBOARD_SORT_DEFAULTS.fetch(normalized_subject).fetch("column")
    direction = preferences["sort_direction"].to_s.presence_in(DASHBOARD_SORT_DIRECTIONS) ||
                DASHBOARD_SORT_DEFAULTS.fetch(normalized_subject).fetch("direction")

    return { column: column, direction: direction } if normalized_subject == "job"

    { "column" => column, "direction" => direction }
  end

  def dashboard_visible_columns(subject)
    subject_key = normalize_dashboard_preference_table(subject)
    required_columns = DASHBOARD_REQUIRED_COLUMNS.fetch(subject_key)
    columns = Array(dashboard_preferences.fetch(subject_key)["visible_columns"]).map(&:to_s)
    required_columns = %w[title] if subject_key == "jobs" && columns.include?("title")
    required_columns = %w[title job] if subject_key == "workflows"

    (required_columns + columns).uniq
  end

  def dashboard_visible_kanban_lanes(subject)
    subject_key = normalize_dashboard_preference_table(subject)
    known_lanes = DASHBOARD_KANBAN_LANES.fetch(subject_key)
    lanes = Array(dashboard_preferences.fetch(subject_key)["kanban_lanes"]).map(&:to_s).reject(&:blank?)
    selected_lanes = lanes.select { |lane| known_lanes.include?(lane) }

    selected_lanes.presence || dashboard_default_kanban_lanes_for(subject_key)
  end

  def update_dashboard_sort!(subject:, column:, direction:)
    subject_key = normalize_dashboard_preference_table(subject)
    normalized_subject = normalize_dashboard_preference_subject(subject)
    column = column.to_s
    direction = direction.to_s

    unless DASHBOARD_SORT_COLUMNS.fetch(normalized_subject).include?(column)
      raise ArgumentError, "Unknown dashboard sort column: #{column}"
    end

    unless DASHBOARD_SORT_DIRECTIONS.include?(direction)
      raise ArgumentError, "Unknown dashboard sort direction: #{direction}"
    end

    updated = dashboard_preferences
    updated[subject_key] = updated.fetch(subject_key).merge(
      "sort_column" => column,
      "sort_direction" => direction
    )

    update!(dashboard_preferences: updated) if updated != dashboard_preferences
  end

  def update_dashboard_columns!(subject:, columns:)
    subject_key = normalize_dashboard_preference_table(subject)
    known_columns = dashboard_known_columns(subject_key)
    required_columns = DASHBOARD_REQUIRED_COLUMNS.fetch(subject_key)
    columns = Array(columns).map(&:to_s).reject(&:blank?)
    unknown_columns = columns - known_columns

    if unknown_columns.any?
      raise ArgumentError, "Unknown dashboard columns: #{unknown_columns.to_sentence}"
    end

    updated = dashboard_preferences
    required_columns = %w[title] if subject_key == "jobs" && columns.include?("repository")
    updated[subject_key] = updated.fetch(subject_key).merge(
      "visible_columns" => (required_columns + columns).uniq
    )

    update!(dashboard_preferences: updated) if updated != dashboard_preferences
  end

  def update_dashboard_kanban_lanes!(subject:, lanes:)
    subject_key = normalize_dashboard_preference_table(subject)
    known_lanes = DASHBOARD_KANBAN_LANES.fetch(subject_key)
    lanes = Array(lanes).map(&:to_s).reject(&:blank?)
    unknown_lanes = lanes - known_lanes

    if unknown_lanes.any?
      raise ArgumentError, "Unknown dashboard Kanban lanes: #{unknown_lanes.to_sentence}"
    end

    updated = dashboard_preferences
    updated[subject_key] = updated.fetch(subject_key).merge(
      "kanban_lanes" => lanes.presence || dashboard_default_kanban_lanes_for(subject_key)
    )

    update!(dashboard_preferences: updated) if updated != dashboard_preferences
  end

  def configured_agent_providers
    AGENT_PROVIDERS.select { |provider| agent_provider_configured?(provider) }
  end

  def alternate_configured_agent_providers
    configured_agent_providers - [ agent_provider ]
  end

  def chat_available?
    claude_oauth_token.present?
  end

  def agent_provider_configured?(provider)
    case provider.to_s
    when "claude"
      claude_oauth_token.present?
    when "codex"
      codex_configured?
    else
      false
    end
  end

  # Generate (and persist) a fresh API token. Returns the
  # plaintext token so the caller can show it to the operator
  # ONCE — it's stored deterministic-encrypted, so the operator
  # who doesn't write it down has to rotate. Crypt-quality random:
  # 32 bytes of urlsafe base64 (~43 chars).
  API_TOKEN_PREFIX = "syrus_".freeze

  def generate_api_token!
    token = API_TOKEN_PREFIX + SecureRandom.urlsafe_base64(32)
    update!(api_token: token)
    token
  end

  def revoke_api_token!
    update!(api_token: nil)
  end

  def clear_credential!(credential)
    credential = credential.to_s
    raise ArgumentError, "Unknown credential: #{credential}" unless CLEARABLE_CREDENTIALS.key?(credential)

    update!(credential => nil)
  end

  # Toggle for the dashboard banner. Set when a GitHub API call
  # returns a permission-class error (403 "Resource not accessible
  # by personal access token", 401, etc.) — so the operator sees a
  # banner pointing at /credentials and polling jobs know to
  # degrade specific endpoints rather than crash. `reason` is the
  # short error string verbatim from Octokit, displayed in the
  # banner so the operator can match against GH docs.
  def mark_gh_api_blocked!(reason)
    return if gh_api_blocked_at && gh_api_blocked_reason == reason  # idempotent — don't bump timestamps for the same recurring error
    update_columns(gh_api_blocked_at: Time.current, gh_api_blocked_reason: reason.to_s[0, 500])
  end

  def clear_gh_api_blocked!
    return unless gh_api_blocked_at
    update_columns(gh_api_blocked_at: nil, gh_api_blocked_reason: nil)
  end

  def gh_api_blocked?
    gh_api_blocked_at.present?
  end

  private

  def codex_configured?
    case codex_auth_mode
    when "api_key"
      codex_api_key.present?
    when "chatgpt_login"
      codex_auth_json.present?
    else
      false
    end
  end

  def normalized_dashboard_preferences(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, preference), hash|
        next if preference.blank?

        normalized_key = key.to_s
        if normalized_key == "visible_columns"
          normalized_dashboard_visible_columns(preference).each do |subject, columns|
            hash[subject] = (hash[subject] || {}).merge("visible_columns" => columns)
          end
          next
        end

        if normalized_key == "dashboard_sorts"
          normalized_dashboard_sorts(preference).each do |subject, sort|
            subject_key = normalize_dashboard_preference_table(subject)
            hash[subject_key] = (hash[subject_key] || {}).merge(
              "sort_column" => sort.fetch("column"),
              "sort_direction" => sort.fetch("direction")
            )
          end
          next
        end

        hash[normalized_key] = normalize_dashboard_preference_value(normalized_key, preference)
      end
    else
      {}
    end
  end

  def normalize_dashboard_preference_value(key, preference)
    case key
    when "last_subject"
      normalize_dashboard_preference_subject(preference)
    when "last_view", "last_ownership_scope", "last_owner_user_id"
      preference.to_s
    when "epics", "jobs", "workflows"
      normalize_dashboard_table_preferences(preference)
    else
      preference.to_s
    end
  end

  def normalize_dashboard_table_preferences(preference)
    return {} unless preference.is_a?(Hash)

    preference.each_with_object({}) do |(key, value), hash|
      next if value.blank?

      normalized_key = key.to_s
      hash[normalized_key] = if normalized_key.in?(%w[visible_columns kanban_lanes])
        Array(value).map(&:to_s)
      else
        value.to_s
      end
    end
  end

  def normalized_dashboard_sorts(value)
    return {} unless value.is_a?(Hash)

    value.each_with_object({}) do |(subject, sort), hash|
      normalized_subject = normalize_dashboard_preference_subject(subject)
      next unless DASHBOARD_SORT_COLUMNS.key?(normalized_subject)
      next unless sort.is_a?(Hash)

      column = sort["column"] || sort[:column]
      direction = sort["direction"] || sort[:direction]
      next unless column.to_s.in?(DASHBOARD_SORT_COLUMNS.fetch(normalized_subject))
      next unless direction.to_s.in?(DASHBOARD_SORT_DIRECTIONS)

      hash[normalized_subject] = { "column" => column.to_s, "direction" => direction.to_s }
    end
  end

  def normalize_dashboard_preference_subject(subject)
    subject.to_s.delete_suffix("s")
  end

  def normalize_dashboard_preference_table(subject)
    key = subject.to_s
    key = "#{key}s" unless key.end_with?("s")
    return key if DASHBOARD_PREFERENCES_DEFAULTS.key?(key) && DASHBOARD_PREFERENCES_DEFAULTS.fetch(key).is_a?(Hash)

    raise ArgumentError, "Unknown dashboard subject: #{subject}"
  end

  def dashboard_known_columns(subject_key)
    optional_columns = DASHBOARD_OPTIONAL_COLUMNS.fetch(subject_key)
    required_columns = DASHBOARD_REQUIRED_COLUMNS.fetch(subject_key)

    (required_columns + optional_columns).uniq
  end

  def deep_merge_dashboard_preferences(defaults, preferences)
    defaults.merge(preferences) do |_key, default_value, preference_value|
      if default_value.is_a?(Hash) && preference_value.is_a?(Hash)
        deep_merge_dashboard_preferences(default_value, preference_value)
      else
        preference_value
      end
    end
  end

  def normalize_dashboard_columns_subject(subject)
    subject.to_s.pluralize.presence_in(DASHBOARD_REQUIRED_COLUMNS.keys)
  end

  def dashboard_default_columns_for(subject)
    DASHBOARD_REQUIRED_COLUMNS.fetch(subject) + DASHBOARD_OPTIONAL_COLUMNS.fetch(subject, [])
  end

  def dashboard_default_kanban_lanes_for(subject)
    DASHBOARD_PREFERENCES_DEFAULTS.fetch(subject).fetch("kanban_lanes").dup
  end

  def normalize_dashboard_columns(subject, columns)
    allowed = dashboard_default_columns_for(subject)
    required = DASHBOARD_REQUIRED_COLUMNS.fetch(subject)
    requested = Array(columns).map(&:to_s)

    (required + requested).select { |column| allowed.include?(column) }.uniq
  end

  def normalized_dashboard_visible_columns(value)
    return {} unless value.is_a?(Hash)

    value.each_with_object({}) do |(subject, columns), hash|
      normalized_subject = normalize_dashboard_columns_subject(subject)
      next unless normalized_subject

      hash[normalized_subject] = normalize_dashboard_columns(normalized_subject, columns)
    end
  end

  def promote_first_user_to_admin
    self.admin = true if User.count.zero?
  end
end
