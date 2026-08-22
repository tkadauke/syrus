class WorkUnitLock < ApplicationRecord
  belongs_to :work_unit

  before_validation :set_acquired_at, on: :create

  validates :lock_key, presence: true, uniqueness: true
  validates :acquired_at, presence: true

  private

  def set_acquired_at
    self.acquired_at ||= Time.current
  end
end
