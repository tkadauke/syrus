module MainBranchHealth
  module AppSettingAccessors
    extend ActiveSupport::Concern

    included do
      attribute :main_concern_report_threshold, :integer, default: 2
      after_save :persist_main_branch_health_setting
    end

    class_methods do
      def main_concern_report_threshold
        return 2 unless MainBranchHealth::Setting.table_exists?

        MainBranchHealth::Setting.current.main_concern_report_threshold
      end
    end

    # Loaded on first use: most AppSetting reads never touch the threshold,
    # and an eager after_find would add a query to every one of them.
    def main_concern_report_threshold
      load_main_branch_health_setting unless @main_branch_health_setting_loaded
      super
    end

    def main_concern_report_threshold=(value)
      load_main_branch_health_setting unless @main_branch_health_setting_loaded
      super
    end

    def reload(...)
      @main_branch_health_setting_loaded = false
      super
    end

    private

    # The plugin's table arrives with its migration; until it has run (a
    # database prepared before this plugin existed) keep the attribute default.
    def main_branch_health_storage_available?
      MainBranchHealth::Setting.table_exists?
    end

    def load_main_branch_health_setting
      @main_branch_health_setting_loaded = true
      return unless persisted? && main_branch_health_storage_available?

      self.main_concern_report_threshold = MainBranchHealth::Setting.current.main_concern_report_threshold
      clear_attribute_change(:main_concern_report_threshold)
    end

    def persist_main_branch_health_setting
      return unless main_branch_health_storage_available?
      return unless previously_new_record? || saved_change_to_main_concern_report_threshold?

      MainBranchHealth::Setting.current.update!(main_concern_report_threshold: main_concern_report_threshold)
      clear_attribute_change(:main_concern_report_threshold)
    end
  end
end
