class Coworkers::Grant < ApplicationRecord
  self.table_name = "coworker_grants"
  APPROVAL_POLICIES = %w[auto confirm queue].freeze

  belongs_to :coworker, inverse_of: :grants
  validates :capability, presence: true, uniqueness: { scope: :coworker_id }
  validates :approval_policy, inclusion: { in: APPROVAL_POLICIES }
  after_initialize :default_constraints, if: :new_record?

  private

  def default_constraints = self.constraints ||= {}
end
