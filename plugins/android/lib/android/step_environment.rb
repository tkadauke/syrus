require "syrus/plugin/step_environment"

module Android
  class StepEnvironment
    include Syrus::Plugin::StepEnvironment

    SDK_KEYS = %w[
      ANDROID_HOME
      ANDROID_SDK_ROOT
    ].freeze

    def self.forwarded_env_keys = SDK_KEYS

    def self.extra_env(scope:, workspace_path:)
      root = Pathname.new(workspace_path).join(".syrus", "android")

      {
        "ANDROID_USER_HOME" => root.to_s,
        "ANDROID_PREFS_ROOT" => root.to_s,
        "ANDROID_AVD_HOME" => root.join("avd").to_s
      }
    end
  end
end
