# frozen_string_literal: true

module Execution
  # Behavior-oriented conformance tests for the versioned Backend contract.
  # Adapters drive real enforcement/transport boundaries; copying request
  # fields into a claimed observation is deliberately not part of this API.
  module BackendTestKit
    PROBE_PAYLOAD = "execution-backend-mcp-probe".freeze
    PROBE_REPLY = "execution-backend-mcp-ok".freeze

    class << self
      def define_examples(rspec, adapter:)
        rspec.describe "Execution::Backend contract v#{Backend::CONTRACT_VERSION}" do
          let(:contract_adapter) { adapter.respond_to?(:call) ? adapter.call(self) : adapter }

          it("enforces mount behavior") { expect(contract_adapter.verify_mount_semantics!).to be(true) }
          it("enforces the grader network profile") { expect(contract_adapter.verify_network_profile!).to be(true) }
          it("applies declared resource limits") { expect(contract_adapter.verify_resource_limits!).to be(true) }

          it "round-trips to the MCP daemon through the backend transport" do
            expect(contract_adapter.mcp_round_trip(PROBE_PAYLOAD)).to eq(PROBE_REPLY)
          end

          BackendTestKit.malformed_requests.each do |label, malformed|
            it "rejects #{label} with the contract error" do
              expect { contract_adapter.run(malformed.call) }.to raise_error(Backend::InvalidRequest)
            end
          end

          it "falls back when the backend declines a valid request" do
            expect(contract_adapter.fallback(BackendTestKit.request)).to be_a(ProcessRunner::Result)
          end

          it "returns the standard process result" do
            expect(contract_adapter.run(BackendTestKit.request)).to be_a(ProcessRunner::Result)
          end
        end
      end

      def malformed_requests
        {
          "a non-request object" => -> { Object.new },
          "an empty command" => -> { request(command: []) },
          "invalid mounts" => -> { request(mounts: Object.new) },
          "an unknown network profile" => -> { request(network: "unconfined-mystery") },
          "invalid resource limits" => -> { request(resource_limits: Object.new) },
          "malformed resource limit values" => lambda {
            request(resource_limits: ResourceLimits.new(memory_max: "many", cpu_max: "fast", io_weight: -1))
          },
          "a non-positive timeout" => -> { request(timeout: 0) }
        }
      end

      def request(**overrides)
        defaults = {
          env: {}, command: [ "true" ], chdir: Dir.pwd, mounts: ProcessRunner.mounts(Dir.pwd),
          network: "grader", resource_limits: nil, timeout: 5, stdin_data: nil,
          unsetenv_others: true, pgroup: true, stop_requested: -> { false },
          on_output_chunk: nil, on_output_line: nil, kill_grace_seconds: 1,
          silent_timeout: nil, activity_probe: nil, kind: "grader", run: nil,
          workflow: nil, job: nil, chat_session: nil, agent: nil,
          display_command: nil, on_spawned_process: nil, local_runner: nil
        }
        Request.new(**defaults.merge(overrides))
      end

      def limits
        ResourceLimits.new(memory_max: "268435456", cpu_max: "50000 100000", io_weight: 200)
      end

      def success_result
        ProcessRunner::Result.new(
          exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false,
          operator_killed: false, aliveness_failed: false, duration_s: 0.0,
          spawned_process_id: nil
        )
      end
    end
  end
end
