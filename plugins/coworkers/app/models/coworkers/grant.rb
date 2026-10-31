class Coworkers::Grant < ApplicationRecord
  self.table_name = "coworker_grants"
  APPROVAL_POLICIES = %w[auto confirm queue].freeze

  belongs_to :coworker, inverse_of: :grants
  validates :capability, presence: true, uniqueness: { scope: :coworker_id }
  validates :approval_policy, inclusion: { in: APPROVAL_POLICIES }
  validate :scope_matches_catalog
  after_initialize :default_constraints, if: :new_record?

  private

  def scope_matches_catalog
    descriptor = Coworkers::GrantCatalog.fetch(capability)
    errors.add(:scope, "is invalid") unless descriptor.valid_scope?(scope, user: coworker&.owner_user)
  rescue KeyError
    errors.add(:capability, "is not declared")
  end

  def default_constraints = self.constraints ||= {}
end
