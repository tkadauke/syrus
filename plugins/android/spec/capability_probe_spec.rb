require "rails_helper"

RSpec.describe Android::CapabilityProbe do
  it "implements the worker capability probe contract" do
    expect(described_class).to respond_to(:capability_probes)
    expect(Syrus::PluginRegistry.providers_for(:worker_capability_probe)).to include(described_class)
  end

  it "advertises the android toolchain" do
    probe = described_class.capability_probes(env: {}).first

    expect(probe[:dimension]).to eq("toolchain")
    expect(probe[:token]).to eq("android")
  end

  # WorkerCapabilities runs probes with an empty env, and the sandbox then
  # supplies a bare /usr/local/bin:/usr/bin:/bin PATH -- so everything the
  # worker image adds through `ENV PATH`, the whole SDK included, is invisible
  # to a probe that names its command. A `sdkmanager` probe reported the
  # toolchain absent on workers that have it.
  it "probes an absolute path rather than relying on PATH" do
    command = described_class.capability_probes(env: {}).first[:command]

    expect(command.first).to start_with("/")
    expect(command.first).to end_with("/platform-tools/adb")
  end

  # adb is native and answers in roughly 12ms; sdkmanager is a JVM program
  # spending about 650ms of a 2 second probe budget.
  it "probes with adb rather than the JVM-backed sdkmanager" do
    command = described_class.capability_probes(env: {}).first[:command]

    expect(command.join(" ")).not_to include("sdkmanager")
  end

  it "resolves the SDK root from the environment, falling back to the shared default" do
    expect(described_class.sdk_root(env: { "ANDROID_SDK_ROOT" => "/custom/sdk" })).to eq("/custom/sdk")
    expect(described_class.sdk_root(env: { "ANDROID_HOME" => "/home/sdk" })).to eq("/home/sdk")
    expect(described_class.sdk_root(env: { "ANDROID_SDK_ROOT" => "" })).to eq(Android::ToolchainDiagnostic::DEFAULT_SDK_ROOT)
    expect(described_class.sdk_root(env: {})).to eq(Android::ToolchainDiagnostic::DEFAULT_SDK_ROOT)
  end

  # The root must come from the same place ToolchainDiagnostic uses, or a
  # worker could advertise a toolchain whose diagnostics look at a different
  # directory.
  it "shares the SDK root default with the toolchain diagnostic" do
    expect(described_class.sdk_root(env: {})).to eq(Android::ToolchainDiagnostic::DEFAULT_SDK_ROOT)
  end
end
