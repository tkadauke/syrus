class SmartFolder < ApplicationRecord
  # `visibility` controls where each built-in renders in the sidebar:
  #   :always       — pinned to the top of the sidebar regardless of count.
  #   :when_present — shown only when the count is non-zero (unless it's
  #                   the active folder, so the operator can navigate away).
  #   :on_demand    — tucked into the "More" disclosure at the bottom of
  #                   the sidebar; still available via direct URL and via
  #                   the attention dropdown.
  # Each built-in's `filter` is a Filters::Ast tree (JSON-friendly).
  # The attention preset chip carries today's union/composite logic
  # internally; over time these can decompose into primitive chip
  # combinations as the chip vocabulary grows.
  def self.attention_preset_filter(preset)
    {
      "and" => [
        { "field" => "attention", "op" => "is", "value" => preset }
      ]
    }
  end

  # Like attention_preset_filter but also pins the results to user-facing
  # job kinds (issue, cron, direct). All predefined job smart folders use
  # this so system/infrastructure jobs (main_grader) don't clutter the
  # operator's normal workflow views. The "All jobs" link uses no filter
  # and deliberately bypasses this restriction.
  def self.user_job_attention_preset_filter(preset)
    {
      "and" => [
        { "field" => "attention", "op" => "is", "value" => preset },
        { "field" => "job_type", "op" => "is", "value" => "user" },
        { "field" => "owner_user_id", "op" => "is", "value" => "me" }
      ]
    }
  end

  def self.epic_attention(preset)
    attention_preset_filter(preset)
  end

  def self.workflow_attention(preset)
    attention_preset_filter(preset)
  end

  JOB_BUILTINS = [
    # First item under "More" — the unfiltered list is useful for lookups
    # but too broad to occupy prime sidebar real estate. Uses no filter so
    # all job kinds appear (including system/infrastructure kinds that the
    # attention-preset folders hide).
    { key: "all_jobs",         name: "All jobs",               visibility: :on_demand,    filter: { "and" => [] } },

    # Tier 1: high-priority alerts. Each appears above the fold only
    # when populated — so an empty sidebar means there's nothing
    # urgent. When populated, they sit near the top where the
    # operator will notice them.
    { key: "pinned",           name: "Pinned",                 visibility: :when_present, filter: user_job_attention_preset_filter("pinned") },
    { key: "in_progress",      name: "In progress",            visibility: :when_present, filter: user_job_attention_preset_filter("in_progress") },
    { key: "queued",           name: "Queued",                 visibility: :when_present, filter: user_job_attention_preset_filter("queued") },
    { key: "invalid",          name: "Invalid",                visibility: :when_present, filter: user_job_attention_preset_filter("needs_review") },
    { key: "awaiting_epic",    name: "Awaiting Epic",          visibility: :when_present, filter: user_job_attention_preset_filter("awaiting_epic") },

    # Tier 2: always-on routing.
    { key: "inbox",            name: "Inbox",                  visibility: :always,       filter: user_job_attention_preset_filter("inbox") },
    { key: "landing_queue",    name: "Landing queue",          visibility: :when_present, filter: user_job_attention_preset_filter("landing_queue") },
    { key: "just_failed",      name: "Just failed",            visibility: :when_present, filter: user_job_attention_preset_filter("just_failed") },
    { key: "blocked",          name: "Blocked",                visibility: :when_present, filter: user_job_attention_preset_filter("blocked") },

    # Tier 3: historical lookups, tucked into "More" disclosure.
    { key: "stale",            name: "Stale",                  visibility: :on_demand,    filter: user_job_attention_preset_filter("stale") },
    { key: "merged_this_week", name: "Merged this week",       visibility: :on_demand,    filter: user_job_attention_preset_filter("merged_this_week") }
  ].freeze
  BUILTIN_DEFINITIONS = JOB_BUILTINS

  def self.epic_attention_with_owner(preset)
    { "and" => [ { "field" => "attention", "op" => "is", "value" => preset }, { "field" => "owner_user_id", "op" => "is", "value" => "me" } ] }
  end

  EPIC_BUILTINS = [
    { key: "epics_mine",          name: "My epics",      visibility: :always,       filter: { "and" => [ { "field" => "owner_user_id", "op" => "is", "value" => "me" } ] } },
    { key: "epics_claimable",     name: "Claimable",     visibility: :always,       filter: { "and" => [ { "field" => "owner_user_id", "op" => "is", "value" => "unclaimed" }, { "field" => "state", "op" => "is_one_of", "value" => %w[backlog ready] } ] } },
    { key: "epics_in_progress",   name: "In progress",   visibility: :always,       filter: epic_attention_with_owner("in_progress") },
    { key: "epics_ready",         name: "Ready",         visibility: :when_present, filter: epic_attention_with_owner("ready_to_start") },
    { key: "epics_blocked",       name: "Blocked",       visibility: :when_present, filter: epic_attention_with_owner("blocked_by_dependency") },
    { key: "epics_stalled",       name: "Stalled",       visibility: :when_present, filter: epic_attention_with_owner("stalled") },
    { key: "epics_empty",         name: "Empty",         visibility: :on_demand,    filter: epic_attention_with_owner("empty") },
    { key: "epics_recently_done", name: "Recently done", visibility: :on_demand,    filter: epic_attention_with_owner("recently_done") },
    { key: "epics_archived",      name: "Archived",      visibility: :on_demand,    filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "archived" } ] } }
  ].freeze

  WORKFLOW_BUILTINS = [
    { key: "workflows_running",     name: "Running",     visibility: :always,       filter: workflow_attention("running") },
    { key: "workflows_stuck",       name: "Stuck",       visibility: :when_present, filter: workflow_attention("stuck") },
    { key: "workflows_just_failed", name: "Just failed", visibility: :when_present, filter: workflow_attention("just_failed") },
    { key: "workflows_queued",      name: "Queued",      visibility: :on_demand,    filter: workflow_attention("queued") }
  ].freeze

  ADMIN_USER_BUILTINS = [
    { key: "admins",               name: "Admins",               visibility: :on_demand,    filter: { "and" => [ { "field" => "admin", "op" => "is", "value" => true } ] } },
    { key: "missing_github_token", name: "Missing GitHub token", visibility: :when_present, filter: { "and" => [ { "field" => "has_github_token", "op" => "is", "value" => false } ] } },
    { key: "missing_claude_token", name: "Missing Claude token", visibility: :when_present, filter: { "and" => [ { "field" => "has_claude_token", "op" => "is", "value" => false } ] } },
    { key: "gh_rate_low",          name: "Rate limit low",       visibility: :when_present, filter: { "and" => [ { "field" => "gh_rate", "op" => "is", "value" => "low" } ] } }
  ].freeze

  SPAWNED_PROCESS_BUILTINS = [
    { key: "running",         name: "Running",         visibility: :always,       filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "running" } ] } },
    { key: "stale",           name: "Stale",           visibility: :when_present, filter: { "and" => [ { "field" => "stale", "op" => "is", "value" => "true" } ] } },
    { key: "recently_failed", name: "Recently failed", visibility: :when_present, filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "failed" }, { "field" => "started_at", "op" => "within_last", "value" => { "n" => 1, "unit" => "hours" } } ] } }
  ].freeze

  ADMIN_QUEUE_BUILTINS = [
    { key: "failed_today",     name: "Failed today",     visibility: :always,       filter: { "and" => [ { "field" => "failed_since", "op" => "within_last", "value" => { "n" => 1, "unit" => "days" } } ] } },
    { key: "failed_this_hour", name: "Failed this hour", visibility: :when_present, filter: { "and" => [ { "field" => "failed_since", "op" => "within_last", "value" => { "n" => 1, "unit" => "hours" } } ] } },
    { key: "admin_queue_runs",    name: "Runs",    visibility: :always, filter: { "and" => [ { "field" => "queue_name", "op" => "is", "value" => "runs" } ] } },
    { key: "admin_queue_chat",    name: "Chat",    visibility: :always, filter: { "and" => [ { "field" => "queue_name", "op" => "is", "value" => "chat" } ] } },
    { key: "admin_queue_default", name: "Default", visibility: :always, filter: { "and" => [ { "field" => "queue_name", "op" => "is", "value" => "default" } ] } },
    { key: "admin_queue_merges",  name: "Merges",  visibility: :always, filter: { "and" => [ { "field" => "queue_name", "op" => "is", "value" => "merges" } ] } }
  ].freeze

  BUILTINS_BY_SUBJECT = {
    "job" => JOB_BUILTINS,
    "epic" => EPIC_BUILTINS,
    "workflow" => WORKFLOW_BUILTINS,
    "admin_user" => ADMIN_USER_BUILTINS,
    "admin_queue" => ADMIN_QUEUE_BUILTINS,
    "spawned_process" => SPAWNED_PROCESS_BUILTINS
  }.freeze

  VISIBILITY_BY_SUBJECT_AND_NAME = BUILTINS_BY_SUBJECT.transform_values do |definitions|
    definitions.to_h { |d| [ d.fetch(:name), d.fetch(:visibility) ] }
  end.freeze

  KEY_BY_SUBJECT_AND_NAME = BUILTINS_BY_SUBJECT.transform_values do |definitions|
    definitions.to_h { |d| [ d.fetch(:name), d.fetch(:key) ] }
  end.freeze

  def self.builtin_key_for(subject_type, name)
    KEY_BY_SUBJECT_AND_NAME.dig(subject_type.to_s, name)
  end

  EPIC_BUILTIN_DEFINITIONS = EPIC_BUILTINS
  WORKFLOW_BUILTIN_DEFINITIONS = WORKFLOW_BUILTINS
  ADMIN_USER_BUILTIN_DEFINITIONS = ADMIN_USER_BUILTINS
  ADMIN_QUEUE_BUILTIN_DEFINITIONS = ADMIN_QUEUE_BUILTINS
  SPAWNED_PROCESS_BUILTIN_DEFINITIONS = SPAWNED_PROCESS_BUILTINS

  KINDS = %w[ builtin user_defined ].freeze
  SUBJECT_TYPES = %w[ job epic workflow admin_user admin_queue spawned_process ].freeze

  belongs_to :user, optional: true

  # MySQL 8 rejects defaults on JSON columns, so seed an empty filter
  # on initialize for new records — keeps `filter: {}` working as the
  # implicit default the migration used to provide.
  after_initialize :seed_defaults, if: :new_record?

  enum :kind, { builtin: "builtin", user_defined: "user_defined" }, validate: true
  enum :subject_type, SUBJECT_TYPES.index_with(&:itself), validate: true

  validates :name, presence: true
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :subject_type, presence: true, inclusion: { in: SUBJECT_TYPES }
  validates :filter, presence: true
  validates :name, uniqueness: { scope: [ :user_id, :subject_type ] }
  validate :builtin_owner_and_user_defined_owner

  scope :for_subject, ->(subject) { where(subject_type: subject.to_s) }
  scope :builtins, ->(subject = :job) { for_subject(subject).builtin.where(user_id: nil).order(:position, :id) }
  scope :for_user, ->(user, subject: :job) { for_subject(subject).user_defined.where(user: user).order(:position, :id) }
  scope :built_in_sidebar_order, -> { builtin.where(user_id: nil).order(:position, :id) }

  def self.ensure_builtins!
    BUILTINS_BY_SUBJECT.each do |subject, definitions|
      ensure_builtin_set!(subject, definitions)
    end
  end

  def self.ensure_builtins_for_subject!(subject)
    subject = subject.to_s
    ensure_builtin_set!(subject, BUILTINS_BY_SUBJECT.fetch(subject))
  end

  def self.ensure_epic_builtins!
    ensure_builtin_set!(:epic, EPIC_BUILTIN_DEFINITIONS)
  end

  def self.ensure_workflow_builtins!
    ensure_builtin_set!(:workflow, WORKFLOW_BUILTIN_DEFINITIONS)
  end

  def self.ensure_admin_user_builtins!
    ensure_builtin_set!(:admin_user, ADMIN_USER_BUILTIN_DEFINITIONS)
  end

  def self.ensure_admin_queue_builtins!
    ensure_builtin_set!(:admin_queue, ADMIN_QUEUE_BUILTIN_DEFINITIONS)
  end

  def self.ensure_spawned_process_builtins!
    ensure_builtin_set!(:spawned_process, SPAWNED_PROCESS_BUILTIN_DEFINITIONS)
  end

  def self.ensure_builtin_set!(subject, definitions)
    subject = subject.to_s
    existing_by_name = builtin.where(user_id: nil, subject_type: subject).index_by(&:name)

    definitions.each_with_index do |definition, index|
      folder = existing_by_name[definition.fetch(:name)] || new(user_id: nil, subject_type: subject, name: definition.fetch(:name))
      folder.assign_attributes(
        kind: "builtin",
        subject_type: subject,
        filter: definition.fetch(:filter),
        position: index
      )
      folder.save! if folder.changed? || folder.new_record?
    end

    # Sweep retired built-ins so they don't keep appearing in the
    # sidebar after we remove or rename a definition. ("Awaiting your
    # move" used to live here; its filter resolved to relation.none.)
    builtin.where(user_id: nil, subject_type: subject).where.not(name: definitions.map { |d| d.fetch(:name) }).destroy_all
  end

  # Sidebar tier for this folder — see BUILTIN_DEFINITIONS for the
  # tier semantics. User-defined folders aren't classified.
  def visibility
    return :user_defined unless builtin?

    VISIBILITY_BY_SUBJECT_AND_NAME.fetch(subject_type, {})[name] || :on_demand
  end

  # Returns the attention-preset value for this folder if its filter
  # is "and-of-an-attention-chip" (today's built-in shape). nil for
  # folders without an attention chip — typically user-defined.
  def attention_preset
    return nil unless filter.is_a?(Hash)

    Array(filter["and"]).each do |chip|
      next unless chip.is_a?(Hash) && chip["field"] == "attention"
      return chip["value"].to_s
    end
    nil
  end

  # Look up a built-in folder by its attention-preset value.
  # `SmartFolder.find_builtin_by_attention("pinned")` is cleaner than
  # walking the AST manually in specs and view helpers.
  def self.find_builtin_by_attention(preset)
    builtins.find { |folder| folder.attention_preset == preset }
  end

  def builtin_key
    return nil unless builtin?
    BUILTINS_BY_SUBJECT.fetch(subject_type, []).find { |d| d[:name] == name }&.fetch(:key)&.to_s
  end

  private

  def seed_defaults
    self.filter ||= {}
    self.subject_type ||= "job"
  end

  def builtin_owner_and_user_defined_owner
    if builtin? && user_id.present?
      errors.add(:user, "must be blank for built-in smart folders")
    elsif user_defined? && user_id.blank?
      errors.add(:user, "must be present for user-defined smart folders")
    end
  end
end
