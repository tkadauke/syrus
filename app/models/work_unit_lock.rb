class WorkUnitLock < ApplicationRecord
  belongs_to :work_unit

  scope :active, -> { where(released_at: nil) }

  before_validation :set_acquired_at, on: :create
  before_validation :sync_active_lock_key

  validates :lock_key, presence: true
  validates :active_lock_key, uniqueness: true, allow_blank: true
  validates :acquired_at, presence: true

  def active?
    released_at.nil?
  end

  def release!
    update!(released_at: released_at || Time.current, active_lock_key: nil)
  end

  private

  def set_acquired_at
    self.acquired_at ||= Time.current
  end

  def sync_active_lock_key
    self.active_lock_key = released_at.present? ? nil : lock_key
  end
end
