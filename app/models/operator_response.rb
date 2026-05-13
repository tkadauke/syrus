class OperatorResponse < ApplicationRecord
  belongs_to :operator_question

  before_validation :set_defaults

  validates :text, presence: true
  validates :responded_at, presence: true

  private

  def set_defaults
    self.responded_at ||= Time.current
  end
end
