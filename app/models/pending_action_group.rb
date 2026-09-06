class PendingActionGroup < ApplicationRecord
  STATES = %w[ pending confirming confirmed rejected ].freeze

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
    PendingActionGroups::ConfirmResult.new(group: self, member_results: member_results)
  end

  def reject_all!
    with_lock do
      return false unless pending?

      chat_pending_actions.pending.find_each(&:reject!)
      update!(state: "rejected", rejected_at: Time.current)
      true
    end
  end

  private

  def confirm_member(member, user:)
    member.confirm!(user: user)
    PendingActionGroups::MemberResult.new(pending_action: member, success: true, error: nil)
  rescue StandardError => e
    PendingActionGroups::MemberResult.new(pending_action: member, success: false, error: e.message)
  end

  def derive_owner_from_chat_session
    return unless chat_session

    self.repository ||= chat_session.repository
    self.user ||= chat_session.user
  end
end
