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

  BUILTIN_DEFINITIONS = [
    { key: "pinned",           name: "Pinned",           visibility: :when_present, filter: attention_preset_filter("pinned") },
    { key: "in_progress",      name: "In progress",      visibility: :when_present, filter: attention_preset_filter("in_progress") },
    { key: "inbox",            name: "Inbox",            visibility: :always,       filter: attention_preset_filter("inbox") },
    { key: "awaiting_approval", name: "Awaiting your approval", visibility: :when_present, filter: attention_preset_filter("awaiting_approval") },
    { key: "just_failed",      name: "Just failed",      visibility: :when_present, filter: attention_preset_filter("just_failed") },
    { key: "in_review",        name: "In review",        visibility: :always,       filter: attention_preset_filter("in_review") },
    { key: "blocked",          name: "Blocked",          visibility: :when_present, filter: attention_preset_filter("blocked") },
    { key: "stale",            name: "Stale",            visibility: :when_present, filter: attention_preset_filter("stale") },
    { key: "awaiting_epic",    name: "Awaiting Epic",    visibility: :on_demand,    filter: attention_preset_filter("awaiting_epic") },
    { key: "needs_review",     name: "Needs review",     visibility: :on_demand,    filter: attention_preset_filter("needs_review") },
    { key: "merged_this_week", name: "Merged this week", visibility: :on_demand,    filter: attention_preset_filter("merged_this_week") }
  ].freeze

  VISIBILITY_BY_NAME = BUILTIN_DEFINITIONS.to_h { |d| [ d.fetch(:name), d.fetch(:visibility) ] }.freeze

  KINDS = %w[ builtin user_defined ].freeze

  belongs_to :user, optional: true

  # MySQL 8 rejects defaults on JSON columns, so seed an empty filter
  # on initialize for new records — keeps `filter: {}` working as the
  # implicit default the migration used to provide.
  after_initialize :seed_empty_filter, if: :new_record?

  enum :kind, { builtin: "builtin", user_defined: "user_defined" }, validate: true

  validates :name, presence: true
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :filter, presence: true
  validates :name, uniqueness: { scope: :user_id }
  validate :builtin_owner_and_user_defined_owner

  scope :builtins, -> { builtin.where(user_id: nil).order(:position, :id) }
  scope :for_user, ->(user) { user_defined.where(user: user).order(:position, :id) }

  def self.ensure_builtins!
    BUILTIN_DEFINITIONS.each_with_index do |definition, index|
      folder = find_or_initialize_by(user_id: nil, name: definition.fetch(:name))
      folder.assign_attributes(
        kind: "builtin",
        filter: definition.fetch(:filter),
        position: index
      )
      folder.save! if folder.changed? || folder.new_record?
    end

    # Sweep retired built-ins so they don't keep appearing in the
    # sidebar after we remove or rename a definition. ("Awaiting your
    # move" used to live here; its filter resolved to relation.none.)
    builtin.where(user_id: nil).where.not(name: BUILTIN_DEFINITIONS.map { |d| d.fetch(:name) }).destroy_all
  end

  # Sidebar tier for this folder — see BUILTIN_DEFINITIONS for the
  # tier semantics. User-defined folders aren't classified.
  def visibility
    return :user_defined unless builtin?

    VISIBILITY_BY_NAME[name] || :on_demand
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

  private

  def seed_empty_filter
    self.filter ||= {}
  end

  def builtin_owner_and_user_defined_owner
    if builtin? && user_id.present?
      errors.add(:user, "must be blank for built-in smart folders")
    elsif user_defined? && user_id.blank?
      errors.add(:user, "must be present for user-defined smart folders")
    end
  end
end
