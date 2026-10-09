require "android/gradle_grader_type"

module Android
  class ManagedDeviceGraderType < GradleGraderType
    DEFAULT_TIMEOUT_MINUTES = 60

    def self.type_name
      "android-managed-device"
    end

    private

    def default_name = "android-managed-device"
    def default_display_name = "Android managed device tests"
    def default_description = "Android Gradle Managed Device tests."
    def grader_mode = "managed_device"

    def default_tasks
      return device_tasks if managed_devices.any?

      [ "allDevicesCheck" ]
    end

    def metadata
      super.merge("managed_devices" => managed_devices)
    end

    def managed_devices
      shell_array(config["devices"] || config["device"])
    end

    def device_tasks
      managed_devices.map { |device| "#{device}#{managed_device_variant}AndroidTest" }
    end

    def managed_device_variant
      raw = config["variant"].to_s.strip.presence || "Debug"
      raw.camelize
    end

    def default_report_paths
      [
        "build/outputs/androidTest-results/managedDevice",
        "*/build/outputs/androidTest-results/managedDevice",
        "build/outputs/androidTest-results/managedDevice/*",
        "*/build/outputs/androidTest-results/managedDevice/*"
      ]
    end

    def default_artifact_paths
      [
        "build/outputs/androidTest-results/managedDevice",
        "*/build/outputs/androidTest-results/managedDevice",
        "build/reports/androidTests/managedDevice",
        "*/build/reports/androidTests/managedDevice",
        "build/outputs/managed_device_android_test_additional_output",
        "*/build/outputs/managed_device_android_test_additional_output"
      ]
    end

    def default_log_paths
      [
        "build/reports/androidTests/managedDevice",
        "*/build/reports/androidTests/managedDevice"
      ]
    end
  end
end
