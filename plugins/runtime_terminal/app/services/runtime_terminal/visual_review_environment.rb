require "json"
require "open3"
require "set"
require "timeout"

module RuntimeTerminal
  class VisualReviewEnvironment
    MAX_INPUT_BYTES = 16.kilobytes
    MAX_OUTPUT_BYTES = 64.kilobytes
    MAX_STDERR_BYTES = 8.kilobytes
    TIMEOUT = 10.seconds
    NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    FORBIDDEN = SyrusYml::VISUAL_REVIEW_FORBIDDEN_ENV.to_set.freeze

    class Error < RuntimeSessionProviders::ConfigurationError; end

    class InputResolver
      def self.for(name)
        { "run_api_endpoint" => RunApiEndpoint, "run_api_credential" => RunApiCredential }.fetch(name) do
          raise Error, "visual-review environment input #{name.inspect} is unknown or unauthorized"
        end
      end
    end

    class RunApiEndpoint
      def self.resolve(_run)
        host = ENV["SYRUS_APP_HOST"].to_s.sub(%r{/\z}, "")
        raise Error, "visual-review environment input run_api_endpoint is unavailable" if host.blank?
        return host if host.match?(%r{\Ahttps?://}i)

        scheme = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SYRUS_ASSUME_SSL", "true")) ? "https" : "http"
        "#{scheme}://#{host}"
      end
    end

    class RunApiCredential
      def self.resolve(run)
        unless run && Run::ACTIVE_STATES.include?(run.state)
          raise Error, "visual-review environment input run_api_credential is unavailable for an inactive Run"
        end

        McpInvocationContext.issue_for_app_run(run, expires_in: 30.minutes)
      end
    end

    def initialize(runtime_session)
      @runtime_session = runtime_session
    end

    def call
      config = runtime_session.metadata.dig("visual_review_target", "environment")
      return {} unless config

      static = validate_mapping(config.fetch("static", {}), source: "static")
      command = config["command"]
      return static unless command

      generated = execute(command)
      duplicate = static.keys & generated.keys
      raise Error, "visual-review environment key #{duplicate.first} is declared by both static and generated configuration" if duplicate.any?

      static.merge(generated)
    end

    private

    attr_reader :runtime_session

    def execute(command)
      inputs = Array(command["inputs"]).to_h do |name|
        [ name, InputResolver.for(name).resolve(runtime_session.run) ]
      end
      payload = JSON.generate("inputs" => inputs)
      raise Error, "visual-review environment input envelope is too large" if payload.bytesize > MAX_INPUT_BYTES

      stdout, stderr, status = capture(Array(command["argv"]), payload)
      raise Error, "visual-review environment command exited with status #{status.exitstatus}; stderr: #{diagnostic(stderr)}" unless status.success?

      parse_output(stdout, Array(command["allow_output"]))
    rescue Errno::ENOENT
      raise Error, "visual-review environment command executable was not found"
    end

    def capture(argv, payload)
      stdout = +"".b
      stderr = +"".b
      status = nil
      Timeout.timeout(TIMEOUT) do
        stdin, out, err, wait = Open3.popen3(
          ProcessRunner.forwarded_env([]), *argv,
          chdir: runtime_session.workspace_ref, pgroup: true
        )
        begin
          stdin.write(payload)
          stdin.close
          readers = [ [ out, stdout, MAX_OUTPUT_BYTES, "stdout" ], [ err, stderr, MAX_STDERR_BYTES, "stderr" ] ].map do |io, buffer, limit, label|
            Thread.new do
              Thread.current.report_on_exception = false
              loop do
                chunk = io.readpartial(4096)
                raise Error, "visual-review environment command #{label} exceeded #{limit} bytes" if buffer.bytesize + chunk.bytesize > limit
                buffer << chunk
              rescue EOFError, IOError
                break
              end
            end
          end
          readers.each(&:value)
          status = wait.value
        ensure
          terminate(wait)
          [ stdin, out, err ].each { |io| io.close unless io.closed? }
        end
      end
      [ stdout.force_encoding(Encoding::UTF_8), stderr.force_encoding(Encoding::UTF_8), status ]
    rescue Timeout::Error
      raise Error, "visual-review environment command timed out after #{TIMEOUT.to_i} seconds"
    end

    def terminate(wait)
      return unless wait&.alive?

      Process.kill("TERM", -wait.pid)
      wait.join(0.5)
      Process.kill("KILL", -wait.pid) if wait.alive?
      wait.join
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def parse_output(stdout, allow_output)
      raise Error, "visual-review environment command stdout is not valid UTF-8" unless stdout.valid_encoding?
      result = {}
      seen = Set.new
      stdout.lines(chomp: true).each do |record|
        name, value = record.split("=", 2)
        raise Error, "visual-review environment command emitted a malformed record" if value.nil? || name.blank?
        validate_name!(name, source: "generated")
        raise Error, "visual-review environment command emitted duplicate key #{name}" if seen.include?(name)
        seen << name
        raise Error, "visual-review environment command emitted NUL for key #{name}" if value.include?("\0")
        result[name] = value if allow_output.include?(name)
      end
      result
    end

    def validate_mapping(mapping, source:)
      mapping.to_h.each_with_object({}) do |(name, value), result|
        validate_name!(name, source: source)
        raise Error, "visual-review #{source} environment value for #{name} contains NUL" if value.to_s.include?("\0")
        result[name] = value.to_s
      end
    end

    def validate_name!(name, source:)
      raise Error, "visual-review #{source} environment key #{name.inspect} is malformed" unless NAME.match?(name.to_s)
      raise Error, "visual-review #{source} environment key #{name} is forbidden for process safety" if FORBIDDEN.include?(name)
    end

    def diagnostic(stderr)
      return "(empty)" if stderr.empty?
      return "invalid UTF-8 output" unless stderr.valid_encoding?

      "redacted (#{stderr.bytesize} bytes)"
    end
  end
end
