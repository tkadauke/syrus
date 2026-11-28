module Syrus
  module Host
    # Reads instance-wide operator settings. Setting storage is not promised.
    module Settings
      def self.ui_engagement_telemetry_enabled? = ::AppSetting.ui_engagement_telemetry_enabled?
      def self.coworker_environment_policy = ::CoworkerEnvironmentPolicy.current
    end
  end
end
