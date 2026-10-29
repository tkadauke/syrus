# frozen_string_literal: true

module Execution
  # Transport-neutral conformance tests for the versioned Backend contract.
  module BackendTestKit
    Observation = Data.define(:mounts, :network, :resource_limits, :env, :mcp_endpoint, :result)

    class << self
      def define_examples(rspec, adapter:)
        rspec.describe "Execution::Backend contract v#{Backend::CONTRACT_VERSION}" do
          let(:contract_adapter) { adapter.respond_to?(:call) ? adapter.call(self) : adapter }

          it "preserves mount access modes and destinations" do
            expect(contract_adapter.call(BackendTestKit.request).mounts).to eq([
              { source: "/host/work", destination: "/work", mode: :read_write },
              { source: "/host/cache", destination: "/cache", mode: :read_only },
              { source: "/host/artifacts", destination: "/artifacts", mode: :read_write }
            ])
          end

          it "enforces the requested network profile" do
            expect(contract_adapter.call(BackendTestKit.request).network).to eq("grader")
          end

          it "translates every declared resource limit" do
            expect(contract_adapter.call(BackendTestKit.request).resource_limits).to eq(
              memory_max: "268435456", cpu_max: "50000 100000", io_weight: 200
            )
          end

          it "makes the MCP daemon reachable at its advertised endpoint" do
            observation = contract_adapter.call(BackendTestKit.request)
            expect(observation.mcp_endpoint).to be_present
            expect(observation.env.fetch("SYRUS_PERSISTENT_MCP_SOCKET")).to eq(observation.mcp_endpoint)
          end

          it "rejects malformed requests with the contract error" do
            expect { contract_adapter.call(BackendTestKit.request(command: [])) }
              .to raise_error(Backend::InvalidRequest, /command/)
          end

          it "returns the standard process result" do
            expect(contract_adapter.call(BackendTestKit.request).result).to be_a(ProcessRunner::Result)
          end
        end
      end

      def request(**overrides)
        mounts = ProcessRunner::Mounts.new(
          workdir: "/host/work",
          read_write: ProcessRunner::Mount.new(host_path: "/host/work", mount_path: "/work"),
          read_only: ProcessRunner::Mount.new(host_path: "/host/cache", mount_path: "/cache"),
          artifacts: ProcessRunner::Mount.new(host_path: "/host/artifacts", mount_path: "/artifacts")
        )
        defaults = {
          env: { "SYRUS_PERSISTENT_MCP_SOCKET" => "/host/mcp.sock" }, command: [ "true" ],
          chdir: "/host/work", mounts: mounts, network: "grader",
          resource_limits: ResourceLimits.new(memory_max: "268435456", cpu_max: "50000 100000", io_weight: 200),
          timeout: 5, stdin_data: nil, unsetenv_others: true, pgroup: true,
          stop_requested: -> { false }, on_output_chunk: nil, on_output_line: nil,
          kill_grace_seconds: 1, silent_timeout: nil, activity_probe: nil, kind: "grader",
          run: nil, workflow: nil, job: nil, chat_session: nil, agent: nil,
          display_command: nil, on_spawned_process: nil, local_runner: nil
        }
        Request.new(**defaults.merge(overrides))
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
