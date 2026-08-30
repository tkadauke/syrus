class ChatGoal < ApplicationRecord
  STATUSES = %w[active paused completed cancelled blocked].freeze
  TERMINAL_STATUSES = %w[completed cancelled blocked].freeze
  NON_TERMINAL_STATUSES = (STATUSES - TERMINAL_STATUSES).freeze
  APPROVAL_POLICIES = %w[manual auto].freeze
  ACTIVE_SLOT = "active".freeze
  MAX_CONSECUTIVE_NO_OP_ITERATIONS = 3
  MAX_CONSECUTIVE_BLOCKED_EVENTS = 3

  belongs_to :chat_session, inverse_of: :chat_goals
  belongs_to :user
  belongs_to :repository, optional: true

  enum :status, STATUSES.index_with(&:itself), validate: true
  enum :approval_policy, APPROVAL_POLICIES.index_with(&:itself), validate: true

  before_validation :seed_owner_from_chat
  before_validation :seed_repository_from_chat
  before_validation :seed_mode_snapshot
  before_validation :sync_active_slot
  before_validation :clear_terminal_fields, unless: :terminal?
  before_validation :stamp_terminal_at, if: :terminal?

  validates :prompt, presence: true
  validates :mode_snapshot, presence: true
  validates :iteration_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :active_slot, uniqueness: { scope: :chat_session_id }, allow_nil: true
  validate :owner_matches_chat
  validate :repository_is_available_to_owner
  validate :policy_is_valid_for_mode

  scope :non_terminal, -> { where(status: NON_TERMINAL_STATUSES) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.start!(chat_session:, user: nil, repository: nil, **attrs)
    chat_session.with_lock do
      existing = chat_session.active_goal
      return existing if existing&.active?

      if existing&.paused?
        existing.assign_attributes(attrs.compact)
        existing.resume!
        return existing
      end

      create!({ chat_session: chat_session, user: user || chat_session.user, repository: repository }.merge(attrs))
    end
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def non_terminal?
    NON_TERMINAL_STATUSES.include?(status)
  end

  def resumable?
    active? || paused?
  end

  def prompt_snapshot
    ChatProposal.goal_prompt_snapshot_for(self)
  end

  def reset_loop_safeguards!
    update!(
      consecutive_no_op_iterations: 0,
      consecutive_blocked_events: 0,
      last_blocked_signature: nil,
      last_iteration_signature: nil
    )
  end

  def record_progress!(signature:)
    update!(
      consecutive_no_op_iterations: 0,
      consecutive_blocked_events: 0,
      last_blocked_signature: nil,
      last_iteration_signature: signature
    )
  end

  def record_no_op_iteration!(signature:)
    count = last_iteration_signature == signature ? consecutive_no_op_iterations.to_i + 1 : 1
    update!(
      consecutive_no_op_iterations: count,
      last_iteration_signature: signature
    )
    count
  end

  def record_blocked_event!(signature:)
    count = last_blocked_signature == signature ? consecutive_blocked_events.to_i + 1 : 1
    update!(
      consecutive_blocked_events: count,
      last_blocked_signature: signature
    )
    count
  end

  def start!
    return true if active?
    return false if terminal?

    update!(status: "active")
  end

  def start = start!

  def pause!
    return true if paused?
    return false if terminal?

    update!(status: "paused")
  end

  def pause = pause!

  def resume!
    return true if active?
    return false if terminal?

    update!(status: "active")
  end

  def resume = resume!

  def stop!(reason: "stopped", details: nil)
    cancel!(reason: reason, details: details)
  end

  def stop(**) = stop!(**)

  def cancel!(reason: "cancelled", details: nil)
    transition_terminal!("cancelled", reason: reason, details: details)
  end

  def cancel(**) = cancel!(**)

  def complete!(reason: "completed", details: nil)
    transition_terminal!("completed", reason: reason, details: details)
  end

  def complete(**) = complete!(**)

  def block!(reason:, details: nil)
    transition_terminal!("blocked", reason: reason, details: details)
  end

  def block(**) = block!(**)

  private

  def transition_terminal!(new_status, reason:, details:)
    return true if status == new_status
    return false if terminal?

    update!(
      status: new_status,
      terminal_reason: reason.to_s.presence || new_status,
      terminal_details: details,
      terminal_at: Time.current
    )
  end

  def seed_owner_from_chat
    self.user ||= chat_session&.user
  end

  def seed_repository_from_chat
    self.repository ||= chat_session&.repository
  end

  def seed_mode_snapshot
    return if mode_snapshot.present?
    return unless chat_session

    self.mode_snapshot = {
      "mode" => chat_session.mode || "planning",
      "chat_provider" => chat_session.chat_provider,
      "chat_model" => chat_session.chat_model,
      "repository_id" => repository_id
    }
  end

  def sync_active_slot
    self.active_slot = non_terminal? ? ACTIVE_SLOT : nil
  end

  def clear_terminal_fields
    self.terminal_at = nil
    self.terminal_reason = nil
    self.terminal_details = nil
  end

  def stamp_terminal_at
    self.terminal_at ||= Time.current
  end

  def owner_matches_chat
    return unless chat_session && user

    errors.add(:user, "must own the chat session") if user_id != chat_session.user_id
  end

  def repository_is_available_to_owner
    return unless repository && user

    return if repository.member_at_least?(user, "read")

    errors.add(:repository, "must be available to the chat owner")
  end

  def policy_is_valid_for_mode
    ChatGoal::ModePolicy.for(mode_snapshot && mode_snapshot["mode"]).validate(self)
  end
end
