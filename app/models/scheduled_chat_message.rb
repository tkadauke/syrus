class ScheduledChatMessage < ApplicationRecord
  FIRE_JOB_CLAIM_DURATION = 10.minutes

  belongs_to :chat_session
  belongs_to :user

  after_create_commit :enqueue_fire_job

  validates :body, presence: true
  validates :fire_at, presence: true

  scope :due, ->(now = Time.current) { where(sent_at: nil, fire_at: ..now) }
  scope :recoverable, ->(now = Time.current) {
    where(fire_job_claimed_until: nil).or(where(fire_job_claimed_until: ..now))
  }

  def enqueue_fire_job
    claim_and_enqueue_fire_job(wait_until: fire_at)
  end

  def claim_and_enqueue_fire_job(wait_until: nil, now: Time.current)
    claimed_until = [ wait_until, now ].compact.max + FIRE_JOB_CLAIM_DURATION
    claimed = self.class
      .where(id: id, sent_at: nil)
      .where("fire_job_claimed_until IS NULL OR fire_job_claimed_until <= ?", now)
      .update_all(fire_job_claimed_until: claimed_until, updated_at: now)
    return false unless claimed == 1

    job = ScheduledChatMessageFireJob.set(wait_until: wait_until).perform_later(id)
    return true if job.successfully_enqueued?

    release_fire_job_claim(claimed_until)
    false
  rescue StandardError
    release_fire_job_claim(claimed_until)
    raise
  end

  private

  def release_fire_job_claim(claimed_until)
    self.class.where(id: id, fire_job_claimed_until: claimed_until)
      .update_all(fire_job_claimed_until: nil, updated_at: Time.current)
  end
end
