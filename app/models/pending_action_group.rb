class PendingActionGroup < ApplicationRecord
  STATES = %w[ pending confirming confirmed rejected dismissed ].freeze

  belongs_to :chat_session
  belongs_to :repository, optional: true
  belongs_to :user
  has_many :chat_pending_actions, dependent: :nullify, inverse_of: :pending_action_group

  enum :state, STATES.index_with(&:itself), validate: true

  before_validation :derive_owner_from_chat_session

  validates :chat_session, :user, presence: true

  def self.create_with_members!(chat_session:, member_attributes:, user: nil, repository: nil, reason: nil)
    raise ArgumentError, "member_attributes must not be empty" if member_attributes.blank?

    ApplicationRecord.transaction do
      group = create!(
        chat_session: chat_session,
        user: user || chat_session.user,
        repository: repository || chat_session.repository,
        reason: reason
      )
      member_attributes.each do |attrs|
        group.chat_pending_actions.create!(chat_session: chat_session, **attrs)
      end
      group
    end
  end

  def confirm_all!(user: nil)
    raise ActiveRecord::RecordNotFound, "pending action group belongs to another user" if user && self.user != user

    should_confirm = with_lock do
      return false unless pending?

      update!(state: "confirming")
      true
    end
    return false unless should_confirm

    member_results = chat_pending_actions.pending.find_each.map { |member| confirm_member(member, user: user) }
    update!(state: "confirmed", confirmed_at: Time.current)
    notify_chat_of_outcome(confirmed_notice, outcome: "confirmed")
    PendingActionGroups::ConfirmResult.new(group: self, member_results: member_results)
  end

  def reject_all!(user: nil)
    raise ActiveRecord::RecordNotFound, "pending action group belongs to another user" if user && self.user != user

    should_reject = with_lock do
      return false unless pending?

      chat_pending_actions.pending.find_each { |member| reject_member(member, user: user) }
      update!(state: "rejected", rejected_at: Time.current)
      true
    end
    return false unless should_reject

    notify_chat_of_outcome(rejected_notice, outcome: "rejected")
    true
  end

  def dismiss!
    with_lock do
      return false unless confirmed? || rejected?

      update!(state: "dismissed")
      true
    end
  end

  def confirmed_notice
    members = chat_pending_actions.reload.to_a
    return spawn_chats_confirmed_notice(members) if members.all? { |member| member.action == "spawn_chat" }

    failed = members.count(&:failed?)
    succeeded = members.count(&:confirmed?)
    return "Confirmed #{succeeded} #{'pending action'.pluralize(succeeded)}." if failed.zero?

    "Confirmed #{succeeded} of #{members.size} pending actions; #{failed} failed."
  end

  def rejected_notice
    "Rejected #{chat_pending_actions.count} pending actions."
  end

  private

  def spawn_chats_confirmed_notice(members)
    lines = members.map do |member|
      if member.confirmed?
        payload = member.payload.to_h
        label = payload["spawned_chat_title"].presence || payload["prompt"].to_s.truncate(60)
        "CHAT-#{payload['spawned_chat_id']} (#{payload['spawned_chat_provider']}), thread_id: #{payload['bridge_thread_id']}: #{label}"
      else
        label = member.payload.to_h["title"].presence || member.payload.to_h["prompt"].to_s.truncate(60)
        "Failed: #{label} — #{member.execution_error}"
      end
    end
    ([ "Spawn chats confirmation result:", "Message a spawned chat with send_chat_message(thread_id: ...)." ] + lines).join("\n")
  end

  def confirm_member(member, user:)
    member.suppress_outcome_notification = true
    member.confirm!(user: user)
    PendingActionGroups::MemberResult.new(pending_action: member, success: true, error: nil)
  rescue StandardError => e
    PendingActionGroups::MemberResult.new(pending_action: member, success: false, error: e.message)
  end

  def reject_member(member, user:)
    member.suppress_outcome_notification = true
    member.reject!(user: user)
  end

  def notify_chat_of_outcome(text, outcome:)
    message = chat_session.messages.create!(
      role: "system",
      content: { "text" => text, "source" => "pending_action_group_notification", "outcome" => outcome }
    )
    chat_session.update!(last_message_at: Time.current)
    chat_session.pin_chat_provider!
    ChatTurnJob.perform_later(chat_session_id, message.id)
  end

  def derive_owner_from_chat_session
    return unless chat_session

    self.repository ||= chat_session.repository
    self.user ||= chat_session.user
  end
end
