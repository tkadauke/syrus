require "rails_helper"

# spec/support/worker_host.rb makes every example run as the canonical
# Linux/amd64 worker so RunJob's capability hand-back cannot make a spec's
# verdict depend on the machine running the suite. Keep that default from
# quietly disappearing.
RSpec.describe "Hermetic worker host for specs" do
  it "reports a Linux worker whatever host the suite runs on" do
    capabilities = WorkerCapabilities.current.fetch(:capabilities)

    expect(capabilities["os"]).to eq([ "linux" ])
    expect(WorkerCapabilities.queue_names_for("runs", capabilities: capabilities)).to include("runs")
  end

  it "ignores an ambient SYRUS_WORKER_CAPABILITIES from the developer's shell" do
    expect(ENV[WorkerCapabilities::ENV_KEY]).to be_nil
    expect(WorkerCapabilities.current.dig(:diagnostics, "configured")).to be(false)
  end

  it "lets an example still configure capabilities explicitly" do
    ENV[WorkerCapabilities::ENV_KEY] = "os:macos,arch:arm64"

    expect(WorkerCapabilities.current.fetch(:capabilities)).to include("os" => [ "macos" ], "arch" => [ "arm64" ])
  end

  it "uses the real host detection when an example opts out", :real_worker_host do
    host_os = RbConfig::CONFIG.fetch("host_os").downcase
    expected = if host_os.include?("darwin") then "macos" elsif host_os.include?("linux") then "linux" end
    skip("host OS #{host_os} has no capability token") unless expected

    expect(WorkerCapabilities.current.dig(:capabilities, "os")).to eq([ expected ])
  end
end
