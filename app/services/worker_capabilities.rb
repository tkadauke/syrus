require "open3"
require "rbconfig"
require_relative "target_graph/execution_capabilities"
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
    "linux" => "amd64",
    "macos" => "arm64"
  }.freeze

  ToolProbe = Data.define(:dimension, :token, :diagnostic_key, :command, :available_value)

  TOOL_PROBES = [
    ToolProbe.new(dimension: "toolchain", token: "xcode", diagnostic_key: "xcode", command: [ "xcodebuild", "-version" ], available_value: true),
    ToolProbe.new(dimension: "runtime", token: "ios_simulator", diagnostic_key: "ios_simulator", command: [ "xcrun", "simctl", "list", "runtimes", "-j" ], available_value: true),
    ToolProbe.new(dimension: "feature", token: "docker", diagnostic_key: "docker", command: [ "docker", "version", "--format", "{{.Server.Version}}" ], available_value: true)
  ].freeze
  VERSION_PROBES = {
    "ruby" => [ RbConfig.ruby, "-e", "print RUBY_ENGINE, ' ', RUBY_VERSION" ],
    "bundler" => [ "bundle", "--version" ],
    "node" => [ "node", "--version" ],
    "npm" => [ "npm", "--version" ],
    "pnpm" => [ "pnpm", "--version" ],
    "yarn" => [ "yarn", "--version" ],
    "bun" => [ "bun", "--version" ],
    "go" => [ "go", "version" ],
    "python" => [ "python3", "--version" ],
    "cargo" => [ "cargo", "--version" ],
    "xcode" => [ "xcodebuild", "-version" ]
  }.freeze

  class << self
    def current
      configured = parse(ENV[ENV_KEY])
      detected = detected_defaults
      merged = detected.fetch(:capabilities).merge(configured)
      merged.delete("arch") if present_value?(configured["os"]) && blank_value?(configured["arch"])
      capabilities = TargetGraph::ExecutionCapabilities.new(**symbolize_keys(merged))

      {
        capabilities: capabilities.to_h,
        diagnostics: detected.fetch(:diagnostics).merge(
          "configured" => configured.any?,
          "env_key" => ENV_KEY,
          "worker_pool_name" => presence(ENV["SYRUS_WORKER_POOL_NAME"])
        )
      }
    end

    # Detection is memoized for the process; tests that stub probes need a way
    # to clear it.
    def reset_detection_cache!
      @detected_defaults = nil
    end

    def parse(raw)
      return {} if blank_value?(raw)

      pairs = raw.to_s.split(/[,\s]+/).filter_map do |entry|
        key, value = entry.split(":", 2)
        key = normalize_key(key)
        value = value.to_s.strip
        next if blank_value?(key) || blank_value?(value)

        [ key, value ]
      end

      normalize(pairs.each_with_object({}) { |(key, value), hash| (hash[key] ||= []) << value })
    end

    def normalize(raw)
      return {} if blank_value?(raw)
      return normalize_string(raw) if raw.is_a?(String)
      return raw.to_h if raw.is_a?(TargetGraph::ExecutionCapabilities)

      unless raw.is_a?(Hash)
        raise ArgumentError, "worker capabilities must be a Hash, String, or TargetGraph::ExecutionCapabilities"
      end

      normalized = raw.to_h.each_with_object({}) do |(key, value), hash|
        dimension = normalize_key(key)
        next unless TargetGraph::ExecutionCapabilities::DIMENSIONS.include?(dimension)

        hash[dimension] = value
      end

      TargetGraph::ExecutionCapabilities.new(**symbolize_keys(normalized)).to_h
    rescue ArgumentError => e
      raise e unless raw.is_a?(Hash)

      TargetGraph::ExecutionCapabilities.new(
        os: supported_values(raw, "os", TargetGraph::ExecutionCapabilities::ALLOWED_OS_VALUES),
        arch: supported_values(raw, "arch"),
        toolchain: supported_values(raw, "toolchain"),
        runtime: supported_values(raw, "runtime")
      ).to_h
    end

    def queue_names_for(base_queue, capabilities: current.fetch(:capabilities))
      capabilities = normalize(capabilities)
      os = Array(capabilities["os"]).first.to_s
      requested_arch = Array(capabilities["arch"]).first
      arch = present_value?(requested_arch) ? requested_arch : DEFAULT_QUEUE_ARCH_BY_OS[os]
      queue_arch = ARCH_QUEUE_ALIASES.fetch(arch, queue_token(arch))

      queues = []
      queues << base_queue.to_s if blank_value?(os) || os == "linux"
      queues << [ base_queue, queue_token(os), queue_arch ].join("-") if present_value?(os) && present_value?(queue_arch)
      queues.uniq
    end

    def environment_fingerprint_metadata
      detected = current
      {
        "capabilities" => detected.fetch(:capabilities),
        "runtime" => {
          "ruby_engine" => RUBY_ENGINE,
          "ruby_version" => RUBY_VERSION,
          "ruby_platform" => RUBY_PLATFORM,
          "host_os" => RbConfig::CONFIG.fetch("host_os", nil).to_s,
          "host_cpu" => RbConfig::CONFIG.fetch("host_cpu", nil).to_s
        },
        "tool_versions" => tool_versions
      }
    end

    private

    # A JSON column can hand back a JSON-encoded string (double-encoded
    # write) or a "key:value" env-style string instead of a Hash.
    def normalize_string(raw)
      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
      return normalize(parsed) if parsed.is_a?(Hash)

      parse(raw)
    end

    # Memoized for the life of the process. Probing spawns a subprocess per
    # TOOL_PROBE, and this runs on every heartbeat
    # (InstanceVersionSupervisor, WorkerHostHealthSampler), so re-detecting
    # each time pays for several processes to learn an answer that cannot
    # change: a worker does not gain a toolchain without being restarted. A
    # worker whose toolchain is changed underneath it reports the old answer
    # until it restarts, which is the same contract the os token already had.
    def detected_defaults
      @detected_defaults ||= detect_defaults
    end

    def detect_defaults
      os = os_token
      capabilities = {}
      capabilities["os"] = [ os ] if TargetGraph::ExecutionCapabilities::ALLOWED_OS_VALUES.include?(os)
      capabilities["arch"] = [ arch_token ] if present_value?(arch_token)
      diagnostics = {
        "os" => os,
        "arch" => arch_token
      }

      TOOL_PROBES.each do |probe|
        result = command_available?(probe.command)
        diagnostics[probe.diagnostic_key] = result
        next unless result && TargetGraph::ExecutionCapabilities::DIMENSIONS.include?(probe.dimension)

        capabilities[probe.dimension] = Array(capabilities[probe.dimension]) | [ probe.token ]
      end

      { capabilities: capabilities, diagnostics: diagnostics }
    end

    def normalize_key(raw)
      key = raw.to_s.strip.downcase
      {
        "toolchains" => "toolchain",
        "runtimes" => "runtime"
      }.fetch(key, key)
    end

    def supported_values(raw, dimension, allowlist = nil)
      value = raw.to_h[dimension] || raw.to_h[dimension.to_sym]
      values = Array(value).map { |entry| entry.to_s.strip.downcase }.reject { |entry| blank_value?(entry) }
      values &= allowlist if allowlist
      values
    end

    def queue_token(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    end

    def symbolize_keys(hash)
      hash.transform_keys { |key| key.to_s.to_sym }
    end

    def os_token
      host_os = RbConfig::CONFIG.fetch("host_os", RUBY_PLATFORM).downcase
      return "macos" if host_os.include?("darwin")
      return "linux" if host_os.include?("linux")
      token = host_os.gsub(/[^a-z0-9_.+-]+/, "_")
      present_value?(token) ? token : "unknown"
    end

    def arch_token
      host_cpu = RbConfig::CONFIG.fetch("host_cpu", RUBY_PLATFORM).downcase
      return "arm64" if host_cpu.match?(/arm64|aarch64/)
      return "x86_64" if host_cpu.match?(/x86_64|amd64/)

      token = host_cpu.gsub(/[^a-z0-9_.+-]+/, "_")
      present_value?(token) ? token : "unknown"
    end

    def command_available?(command)
      _output, status = Timeout.timeout(PROBE_TIMEOUT_SECONDS) { Open3.capture2e(*command) }
      status.success?
    rescue Errno::ENOENT
      false
    rescue Timeout::Error
      debug_log { "[WorkerCapabilities] probe timed out #{command.first}" }
      false
    rescue StandardError => e
      debug_log { "[WorkerCapabilities] probe failed #{command.first}: #{e.class}: #{e.message}" }
      false
    end

    def tool_versions
      VERSION_PROBES.filter_map do |name, command|
        output, status = Timeout.timeout(PROBE_TIMEOUT_SECONDS) { Open3.capture2e(*command) }
        next unless status.success?

        version = output.to_s.lines.first.to_s.strip
        next if blank_value?(version)

        [ name, version ]
      rescue Errno::ENOENT, Timeout::Error
        nil
      rescue StandardError => e
        debug_log { "[WorkerCapabilities] version probe failed #{command.first}: #{e.class}: #{e.message}" }
        nil
      end.to_h
    end

    def blank_value?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def present_value?(value)
      !blank_value?(value)
    end

    def presence(value)
      present_value?(value) ? value : nil
    end

    def debug_log(&block)
      return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Rails.logger.debug(&block)
    end
  end
end
