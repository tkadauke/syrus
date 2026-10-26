require "syrus/plugin/worker_capability_probe"
require "android/toolchain_diagnostic"

module Android
  # Tells Syrus that a worker with the Android SDK installed can run Android
  # graders. Android::GradleGraderType requires `toolchain=android`, and until
  # something advertised it RunQueueResolver could satisfy that requirement on
  # no worker at all -- every Android grader resolved to `no_capable_worker`,
  # including the preflight graders of main-branch repair.
  #
  # This lives in the plugin because the SDK's location and layout are the
  # plugin's knowledge: ToolchainDiagnostic already resolves the same root from
  # ANDROID_SDK_ROOT/ANDROID_HOME and already knows `platform-tools` holds adb.
  # Core only knows how to ask.
  class CapabilityProbe
    include Syrus::Plugin::WorkerCapabilityProbe

    TOKEN = "android".freeze

    # Absolute path, NOT a PATH lookup. WorkerCapabilities runs probes with an
    # empty env, and the sandbox then supplies a bare
    # `/usr/local/bin:/usr/bin:/bin:...` PATH -- so everything the worker image
    # adds through `ENV PATH`, the whole SDK included, is invisible to a probe
    # that names its command. A `sdkmanager` probe reported the toolchain
    # absent on workers that have it.
    #
    # adb over sdkmanager on its own merits too: a native binary answering in
    # about 12ms, where sdkmanager is a JVM program spending roughly 650ms of a
    # 2 second probe budget.
    def self.capability_probes(env: ENV)
      [
        {
          dimension: "toolchain",
          token: TOKEN,
          diagnostic_key: TOKEN,
          command: [ adb_path(env: env), "--version" ]
        }
      ]
    end

    def self.adb_path(env: ENV)
      File.join(sdk_root(env: env), "platform-tools", "adb")
    end

    def self.sdk_root(env: ENV)
      values = env.to_h.transform_keys(&:to_s)
      root = values["ANDROID_SDK_ROOT"].to_s
      root = values["ANDROID_HOME"].to_s if root.empty?
      root.empty? ? ToolchainDiagnostic::DEFAULT_SDK_ROOT : root
    end
  end
end
