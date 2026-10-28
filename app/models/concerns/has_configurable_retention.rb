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

      definition = RetentionPolicyRegistry.definitions.find { |candidate| candidate.setting_key == retention_setting_key }
      raise KeyError, "no active retention policy for #{retention_setting_key}" unless definition

      definition.retention_window
    end

    def retention_cutoff
      window = retention_window
      window ? window.ago : nil
    end

    # Rows older than the retention window are guaranteed gone, so callers
    # correlating other data (Runs, command spans, query "since" defaults)
    # against this model's history clamp to this floor instead of querying
    # earlier than what could possibly still exist. Infinite retention
    # (window nil) means no clamp is needed, so it returns the epoch.
    def retention_floor(now: Time.current)
      window = retention_window
      window ? now - window : Time.at(0)
    end
  end
end
