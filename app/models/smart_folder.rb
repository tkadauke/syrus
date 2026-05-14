class SmartFolder < ApplicationRecord
  BUILTIN_DEFINITIONS = [
    { key: "inbox", name: "Inbox", filter: { "attention" => "inbox" } },
    { key: "just_failed", name: "Just failed", filter: { "attention" => "just_failed" } },
    { key: "in_review", name: "In review", filter: { "attention" => "in_review" } },
    { key: "stale", name: "Stale", filter: { "attention" => "stale" } },
    { key: "blocked", name: "Blocked", filter: { "attention" => "blocked" } },
    { key: "merged_this_week", name: "Merged this week", filter: { "attention" => "merged_this_week" } }
  ].freeze

  KINDS = %w[ builtin user_defined ].freeze

  belongs_to :user, optional: true

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
  end

  private

  def builtin_owner_and_user_defined_owner
    if builtin? && user_id.present?
      errors.add(:user, "must be blank for built-in smart folders")
    elsif user_defined? && user_id.blank?
      errors.add(:user, "must be present for user-defined smart folders")
    end
  end
end
