class RetentionPolicySetting < ApplicationRecord
  validates :retention_key, presence: true, uniqueness: true
  validates :retention_seconds, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :archive_before_delete, inclusion: { in: [ true, false ] }, allow_nil: true

  def self.for(definition)
    find_by(retention_key: definition.key.to_s) || new(
      retention_key: definition.key.to_s,
      retention_seconds: definition.default_seconds,
      archive_before_delete: definition.archivable ? false : nil
    )
  end

  def self.write!(definition, retention_value: :unchanged, archive_before_delete: :unchanged)
    setting = find_or_initialize_by(retention_key: definition.key.to_s)
    setting.retention_seconds = definition.default_seconds if setting.new_record?
    setting.archive_before_delete = definition.archivable ? false : nil if setting.new_record?
    setting.retention_seconds = definition.seconds_for(retention_value) unless retention_value == :unchanged
    setting.archive_before_delete = archive_before_delete unless archive_before_delete == :unchanged
    setting.archive_before_delete = nil unless definition.archivable
    setting.save!
    setting
  end
end
