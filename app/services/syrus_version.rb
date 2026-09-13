require "socket"

# Build/runtime identity for this process. SHA is baked into the
# Docker image at build time by `bin/deploy` via --build-arg
# GIT_SHA=$(git rev-parse --short HEAD), surfaced through the
# GIT_SHA env var. Role comes from the K8s manifest's SYRUS_ROLE
# env var (web / worker). Locally, both fall back to "dev"/"local".
module SyrusVersion
  module_function

  def current
    ENV.fetch("GIT_SHA", "dev")
  end

  def role
    ENV.fetch("SYRUS_ROLE", "local")
  end

  def hostname
    Socket.gethostname
  end

  def sidecar_process?
    ENV["SYRUS_MCP_SIDECAR"].present? || ENV["SYRUS_CHAT_MCP_SIDECAR"].present?
  end

  # True when this Rails process is one whose lifetime is worth tracking
  # in the instance_versions table — i.e. a web pod or a worker pod.
  # Skips rake tasks, console, tests, migrations. Driven by SYRUS_ROLE
  # being set explicitly in K8s manifests plus the process command being a
  # long-lived server/worker command, so ad hoc Rails runners inside a pod do
  # not register and finalize transient rows.
  def server_process?
    ENV["SYRUS_ROLE"].present? && server_command? && !sidecar_process? && !Rails.env.test?
  end

  def server_command?
    program = File.basename($PROGRAM_NAME.to_s)
    argv = ARGV.map(&:to_s)
    return true if program.in?(%w[jobs puma pumactl thrust])
    return true if program == "rails" && argv.first == "server"
    return true if program == "bin/rails" && argv.first == "server"
    return true if argv.include?("server") && argv.any? { |arg| arg.end_with?("bin/rails", "/rails") }

    false
  end
end
