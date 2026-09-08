class RuntimeSession < ApplicationRecord
  include PluginDataCleanup

  STATES = %w[starting building running idle failed stopping stopped].freeze

  belongs_to :repository
  belongs_to :chat_session, optional: true
  belongs_to :job, optional: true
  belongs_to :workflow, optional: true
  belongs_to :run, optional: true

  has_many :runtime_control_leases, dependent: :destroy

  attribute :capabilities, :json, default: -> { {} }
  attribute :metadata, :json, default: -> { {} }

  validates :workspace_ref, :provider_key, :display_name, presence: true
  validates :state, inclusion: { in: STATES }

  scope :active, -> { where.not(state: %w[failed stopped]) }
  scope :primary, -> { where(primary: true) }
  scope :for_provider, ->(provider_key) { where(provider_key: provider_key) }

  def active? = !%w[failed stopped].include?(state)
  def failed? = state == "failed"
  def stopped? = state == "stopped"

  # The agent's currently active input-mode control lease, if any — the gate
  # DOC-17 requires before delivering pointer/keyboard/touch/etc. events on
  # this session's behalf.
  def active_agent_input_lease
    runtime_control_leases.active.held_by("agent").for_mode("input").first
  end

  def agent_input_lease_active?
    active_agent_input_lease.present?
  end
end
