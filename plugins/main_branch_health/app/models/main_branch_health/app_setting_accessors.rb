module MainBranchHealth
  module AppSettingAccessors
    extend ActiveSupport::Concern

    included do
      attribute :main_concern_report_threshold, :integer, default: 2
      after_find :load_main_branch_health_setting
      after_save :persist_main_branch_health_setting
    end

    class_methods do
      def main_concern_report_threshold = MainBranchHealth::Setting.current.main_concern_report_threshold
    end

    def reload(...)
      super.tap { load_main_branch_health_setting }
    end

    private

    def load_main_branch_health_setting
      self.main_concern_report_threshold = MainBranchHealth::Setting.current.main_concern_report_threshold
      clear_attribute_change(:main_concern_report_threshold)
    end

    def persist_main_branch_health_setting
      return unless previously_new_record? || saved_change_to_main_concern_report_threshold?

      MainBranchHealth::Setting.current.update!(main_concern_report_threshold: main_concern_report_threshold)
      clear_attribute_change(:main_concern_report_threshold)
    end
  end
end
