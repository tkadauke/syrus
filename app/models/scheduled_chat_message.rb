class ScheduledChatMessage < ApplicationRecord
  belongs_to :chat_session
  belongs_to :user

  after_create_commit :enqueue_fire_job

  validates :body, presence: true
  validates :fire_at, presence: true

  scope :due, -> { where(sent_at: nil).where(fire_at: ..Time.current) }

  def enqueue_fire_job
    ScheduledChatMessageFireJob.set(wait_until: fire_at).perform_later(id)
  end
end
