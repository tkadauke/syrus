# Every example runs as the canonical Linux/amd64 worker, whatever machine the
# suite is on.
#
# WorkerCapabilities.current detects os/arch from the host (RbConfig) and reads
# SYRUS_WORKER_CAPABILITIES from the ambient environment. RunJob asks
# RunQueueResolver.locally_satisfied? before starting a compute Run and hands
# the Run back when this process does not satisfy its placement (Linux by
# default). Left to the host, a developer's Mac hands every such Run back, the
# spec's Run stays queued, and the suite's verdict depends on the machine it
# runs on -- which hides real regressions behind "known local failures".
#
# Pinning the detected host here makes that the default for every spec, so a
# new RunJob-driven spec cannot silently depend on the host again. Specs that
# exercise a different worker still stub `WorkerCapabilities.current`,
# `os_token`/`arch_token`, or set SYRUS_WORKER_CAPABILITIES inside the example;
# those later stubs win. A spec that genuinely needs the real host detection
# opts out with `:real_worker_host`.
module WorkerHostSpecDefaults
  OS = "linux".freeze
  ARCH = "x86_64".freeze
  AMBIENT_ENV_KEYS = [ WorkerCapabilities::ENV_KEY, "SYRUS_WORKER_POOL_NAME" ].freeze
end

RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:real_worker_host]

    allow(WorkerCapabilities).to receive(:os_token).and_return(WorkerHostSpecDefaults::OS)
    allow(WorkerCapabilities).to receive(:arch_token).and_return(WorkerHostSpecDefaults::ARCH)
    @worker_host_saved_env = WorkerHostSpecDefaults::AMBIENT_ENV_KEYS.to_h { |key| [ key, ENV.delete(key) ] }
  end

  config.after do
    next unless @worker_host_saved_env

    @worker_host_saved_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    @worker_host_saved_env = nil
  end
end
