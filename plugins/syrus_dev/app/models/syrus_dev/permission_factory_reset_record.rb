module SyrusDev
  class PermissionFactoryResetRecord < ApplicationRecord
    self.table_name = "syrus_dev_permission_factory_resets"

    OUTCOMES = %w[started succeeded failed].freeze

    belongs_to :initiated_by_user, class_name: "User"

    validates :scope_type, :default_version, presence: true
    validates :outcome, inclusion: { in: OUTCOMES }
    validate { errors.add(:counts, "must be a JSON object") unless counts.is_a?(Hash) }

    before_destroy { raise ActiveRecord::ReadOnlyRecord, "Permission factory reset records are immutable" }
    validate :completed_record_is_immutable, on: :update

    private

    def completed_record_is_immutable
      return if outcome_in_database == "started"
      return unless changes_to_save.except("updated_at").any?

      errors.add(:base, "Completed permission factory reset records are immutable")
    end
  end
end
