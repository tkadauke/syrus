require "open3"
require "rbconfig"
require "timeout"

class WorkerCapabilities
  ENV_KEY = "SYRUS_WORKER_CAPABILITIES".freeze
  PROBE_TIMEOUT_SECONDS = 2
  ARCH_QUEUE_ALIASES = {
    "x86_64" => "amd64",
    "x64" => "amd64",
    "amd64" => "amd64",
    "arm64" => "arm64",
    "aarch64" => "arm64"
  }.freeze
  DEFAULT_QUEUE_ARCH_BY_OS = {
    "macos" => "arm64",
    "windows" => "amd64"
  }.freeze

  ToolProbe = Data.define(:dimension, :token, :diagnostic_key, :command, :available_value)

  TOOL_PROBES = [
    ToolProbe.new(dimension: "toolchains", token: "xcode", diagnostic_key: "xcode", command: [ "xcodebuild", "-version" ], available_value: true),
    ToolProbe.new(dimension: "runtimes", token: "ios_simulator", diagnostic_key: "ios_simulator", command: [ "xcrun", "simctl", "list", "runtimes", "-j" ], available_value: true),
    ToolProbe.new(dimension: "features", token: "docker", diagnostic_key: "docker", command: [ "docker", "version", "--format", "{{.Server.Version}}" ], available_value: true)
  ].freeze

  class << self
    def current
      configured = parse(ENV[ENV_KEY])
      detected = detected_defaults
      merged = detected.fetch(:capabilities).merge(configured)
      capabilities = TargetGraph::ExecutionCapabilities.new(**merged.symbolize_keys)

      {
        capabilities: capabilities.to_h,
        diagnostics: detected.fetch(:diagnostics).merge(
          "configured" => configured.present?,
          "env_key" => ENV_KEY
        )
      }
    end

    def parse(raw)
      return {} if raw.blank?

      pairs = raw.to_s.split(/[,\s]+/).filter_map do |entry|
        key, value = entry.split(":", 2)
        key = normalize_key(key)
        value = value.to_s.strip
        next if key.blank? || value.blank?

        [ key, value ]
      end

      normalize(pairs.each_with_object({}) { |(key, value), hash| (hash[key] ||= []) << value })
    end

    def normalize(raw)
      return {} if raw.blank?

      TargetGraph::ExecutionCapabilities.new(**raw.to_h.slice(*TargetGraph::ExecutionCapabilities::DIMENSIONS).symbolize_keys).to_h
    end

    def queue_names_for(base_queue, capabilities: current.fetch(:capabilities))
      capabilities = normalize(capabilities)
      os = Array(capabilities["os"]).first.to_s
      arch = Array(capabilities["arch"]).first.to_s
      arch = DEFAULT_QUEUE_ARCH_BY_OS[os] if arch.blank?
      queue_arch = ARCH_QUEUE_ALIASES.fetch(arch, queue_token(arch))

      queues = []
      queues << base_queue.to_s if os.blank? || os == "linux"
      queues << [ base_queue, queue_token(os), queue_arch ].join("-") if os.present? && queue_arch.present?
      queues.uniq
    end

    private

    def detected_defaults
      capabilities = {
        "os" => [ os_token ],
        "arch" => [ arch_token ]
      }
      diagnostics = {
        "os" => os_token,
        "arch" => arch_token
      }

      TOOL_PROBES.each do |probe|
        result = command_available?(probe.command)
        diagnostics[probe.diagnostic_key] = result
        (capabilities[probe.dimension] ||= []) << probe.token if result == probe.available_value
      end

      { capabilities: capabilities, diagnostics: diagnostics }
    end

    def normalize_key(raw)
      key = raw.to_s.strip.downcase
      {
        "toolchain" => "toolchains",
        "runtime" => "runtimes",
        "feature" => "features"
      }.fetch(key, key)
    end

    def queue_token(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    end

    def os_token
      host_os = RbConfig::CONFIG.fetch("host_os", RUBY_PLATFORM).downcase
      return "macos" if host_os.include?("darwin")
      return "linux" if host_os.include?("linux")
      return "windows" if host_os.match?(/mswin|mingw|cygwin/)

      host_os.gsub(/[^a-z0-9_.+-]+/, "_").presence || "unknown"
    end

    def arch_token
      host_cpu = RbConfig::CONFIG.fetch("host_cpu", RUBY_PLATFORM).downcase
      return "arm64" if host_cpu.match?(/arm64|aarch64/)
      return "x86_64" if host_cpu.match?(/x86_64|amd64/)

      host_cpu.gsub(/[^a-z0-9_.+-]+/, "_").presence || "unknown"
    end

    def command_available?(command)
      _output, status = Timeout.timeout(PROBE_TIMEOUT_SECONDS) { Open3.capture2e(*command) }
      status.success?
    rescue Errno::ENOENT
      false
    rescue Timeout::Error
      Rails.logger.debug { "[WorkerCapabilities] probe timed out #{command.first}" }
      false
    rescue StandardError => e
      Rails.logger.debug { "[WorkerCapabilities] probe failed #{command.first}: #{e.class}: #{e.message}" }
      false
    end
  end
end
