require "rails_helper"
require "execution/backend_test_kit"

class LocalBackendContractAdapter
  def call(request)
    runner = Object.new
    runner.define_singleton_method(:run_with_local_backend) { Execution::BackendTestKit.success_result }
    request = request.with(local_runner: runner)
    result = Execution::Local.new.run(request)
    Execution::BackendTestKit::Observation.new(
      mounts: request.mounts.read_write.map { |m| mount(m, :read_write) } +
        request.mounts.read_only.map { |m| mount(m, :read_only) } +
        [ mount(request.mounts.artifacts, :read_write) ],
      network: request.network, resource_limits: request.resource_limits.to_h,
      env: request.env, mcp_endpoint: request.env["SYRUS_PERSISTENT_MCP_SOCKET"], result: result
    )
  end

  private

  def mount(value, mode) = { source: value.host_path, destination: value.mount_path, mode: mode }
end

Execution::BackendTestKit.define_examples(RSpec, adapter: ->(_example) { LocalBackendContractAdapter.new })

RSpec.describe Execution::Router do
  it "falls back to Local when every provider declines a valid request" do
    runner = Object.new
    called = false
    runner.define_singleton_method(:run_with_local_backend) { called = true }
    request = Execution::BackendTestKit.request(local_runner: runner)

    described_class.new.run(request)

    expect(called).to be(true)
  end

  it "rejects malformed requests before consulting providers" do
    expect { described_class.new.run(Execution::BackendTestKit.request(command: [])) }
      .to raise_error(Execution::Backend::InvalidRequest, /command/)
  end
end
