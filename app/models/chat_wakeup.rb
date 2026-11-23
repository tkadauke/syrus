class ChatWakeup < ApplicationRecord
  belongs_to :chat_session
  belongs_to :user
  # The wakeup whose turn scheduled this one (NY34); nil when a human turn did.
  belongs_to :source_wakeup, class_name: "ChatWakeup", optional: true

  enum :state, { pending: "pending", fired: "fired", cancelled: "cancelled" }

  after_create_commit :enqueue_fire_job

  validates :prompt, presence: true
  validates :fire_at, presence: true

  attribute :metadata, default: -> { {} }

  def enqueue_fire_job
    ChatWakeupFireJob.set(wait_until: fire_at).perform_later(id)
  end
end
