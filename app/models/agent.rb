class Agent < ApplicationRecord
  belongs_to :resumable, polymorphic: true
  has_many :spawned_processes, dependent: :nullify

  validates :resumable, presence: true
  validates :resumable_id, uniqueness: { scope: :resumable_type }

  def self.find_or_create_for!(resumable)
    create!(resumable: resumable)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    raise unless unique_resumable_collision?(e)

    find_by!(resumable: resumable)
  end

  def provider_session
    resumable.provider_session
  end

  def self.unique_resumable_collision?(error)
    return true if error.is_a?(ActiveRecord::RecordNotUnique)

    error.record.is_a?(self) && error.record.errors.added?(:resumable_id, :taken, value: error.record.resumable_id)
  end
  private_class_method :unique_resumable_collision?
end
