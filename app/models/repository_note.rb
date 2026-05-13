class RepositoryNote < ApplicationRecord
  AUTHORS = %w[ operator agent ].freeze

  belongs_to :repository

  scope :active, -> { where(removed_at: nil) }

  validates :body, presence: true
  validates :author, presence: true, inclusion: { in: AUTHORS }

  def removed?
    removed_at.present?
  end

  def remove!
    update!(removed_at: Time.current)
  end
end
