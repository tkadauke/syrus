class WorkUnitLock < ApplicationRecord
  belongs_to :work_unit

  scope :active, -> { where(released_at: nil) }

  before_validation :set_acquired_at, on: :create

  validates :lock_key, presence: true
  validates :acquired_at, presence: true

  def active?
    released_at.nil?
  end

  def release!
    update!(released_at: released_at || Time.current)
  end

  private

  def set_acquired_at
    self.acquired_at ||= Time.current
  end
end
