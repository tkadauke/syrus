module Syrus
  module Host
    # Reads instance-wide operator settings. Setting storage is not promised.
    module Settings
      def self.ui_engagement_telemetry_enabled? = ::AppSetting.ui_engagement_telemetry_enabled?
      def self.executable_scratch_enabled? = ::RuntimeImages::EnvironmentPolicy.value("scratch", "enabled")
      def self.executable_scratch_size_bytes = ::RuntimeImages::EnvironmentPolicy.value("scratch", "size_bytes")
    end
  end
end
