module HasConfigurableRetention
  extend ActiveSupport::Concern

  included do
    class_attribute :retention_setting_key, instance_writer: false
    class_attribute :retention_unit, instance_writer: false, default: :days
  end

  class_methods do
    # Declares which AppSetting column and unit (days/hours) drive this
    # model's retention window. 0 means infinite retention, matching the
    # existing video_storage_budget_mb "0 = unlimited" convention.
    def configurable_retention(setting_key:, unit: :days)
      self.retention_setting_key = setting_key
      self.retention_unit = unit
    end

    # nil means infinite retention (never prune).
    def retention_window
      raise NotImplementedError, "#{name} did not call configurable_retention" unless retention_setting_key

      value = AppSetting.current.public_send(retention_setting_key).to_i
      return nil if value.zero?

      value.public_send(retention_unit)
    end

    def retention_cutoff
      window = retention_window
      window ? window.ago : nil
    end
  end
end
