class PluginChange < ApplicationRecord
  ACTIONS = %w[install update remove].freeze
  STATUSES = %w[pending confirmed superseded].freeze

  belongs_to :plugin_release, optional: true
  belongs_to :staged_by, class_name: "User"
  belongs_to :confirmed_by, class_name: "User", optional: true

  attribute :capability_manifest, :json, default: -> { {} }

  validates :plugin_name, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :plugin_release, presence: true, unless: :remove?

  scope :pending, -> { where(status: "pending") }

  def remove? = action == "remove"
end
