module RuntimeImages
  # Conformance of a coworker base image to its runtime ABI, as reported by the
  # in-image probe (images/coworker-base/syrus-base-probe).
  #
  # The expected check list is derived from the contract (abi.yml) and the base
  # definition (base.yml), never from the probe's own output, so a probe that
  # silently skips a provider or a confinement check cannot pass: a check that
  # is expected but absent is a failure just like one that reports "fail".
  #
  # Two uses:
  #   - definition_problems: static check that the probe script can emit every
  #     expected check (run by CoworkerBase.validate, so a provider added to the
  #     base without a probe fails the definition);
  #   - evaluate: judge the output of a real probe run against an image.
  class ConformanceProbe
    SCRIPT = CoworkerBase::DIRECTORY.join("syrus-base-probe").freeze
    BUILD_MODE = :build
    FULL_MODE = :full
    MODES = [ BUILD_MODE, FULL_MODE ].freeze

    # Checks that need the real confinement; the build-time smoke test skips them.
    CONFINEMENT_CHECKS = %w[
      read-only-root confinement-no-new-privs confinement-caps-dropped
      mount-writable-workspace mount-writable-coworker mount-writable-tmp mount-tmp-options
      mcp-socket-dir mcp-socket-path
    ].freeze

    # +code+ is machine-readable (stable); +message+ is for operators.
    Problem = Data.define(:code, :message)

    class Result
      attr_reader :problems, :checks

      def initialize(problems, checks)
        @problems = problems.freeze
        @checks = checks.freeze
      end

      def conformant? = problems.empty?
      def codes = problems.map(&:code)
      def messages = problems.map(&:message)
    end

    class NonConformant < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("coworker base is not conformant: #{result.messages.join("; ")}")
      end
    end

    class << self
      # Names of every check a probe of +mode+ must report.
      def expected_checks(mode: FULL_MODE)
        raise ArgumentError, "unknown probe mode #{mode.inspect}" unless MODES.include?(mode)

        names = %w[abi-entrypoint identity identity-name abi-contract no-baked-credentials]
        names += provider_keys.flat_map { |key| [ "provider-#{key}", "abi-path-#{key}" ] }
        names += directory_checks
        names += support_tools.map { |tool| "tool-#{tool}" }
        names += CONFINEMENT_CHECKS if mode == FULL_MODE
        names
      end

      # Static: the probe script contains every check, provider path, tool, and
      # contracted path it is expected to verify.
      def definition_problems(script: SCRIPT.read)
        problems = []
        fixed_check_names.each do |name|
          problems << "syrus-base-probe does not report check #{name}" unless script.include?(name)
        end
        RuntimeAbi.providers.each do |key, provider|
          problems << "syrus-base-probe does not probe provider #{key}" unless script.match?(/\b#{Regexp.escape(key)}\b/)
          problems << "syrus-base-probe does not check #{key} at #{provider.fetch("path")}" unless script.include?("#{key}:#{provider.fetch("path")}")
        end
        support_tools.each do |tool|
          problems << "syrus-base-probe does not check support tool #{tool}" unless script.match?(/for tool in [^;\n]*\b#{Regexp.escape(tool)}\b/)
        end
        socket = RuntimeAbi.contract.dig("mcp", "socket")
        problems << "syrus-base-probe does not check the MCP socket #{socket}" unless script.include?(socket)
        RuntimeAbi.contract.dig("filesystem", "tmp", "options").each do |option|
          problems << "syrus-base-probe does not check /tmp option #{option}" unless script.include?(option)
        end
        problems << "syrus-base-probe does not check the confinement policy" unless script.include?("NoNewPrivs") && script.include?("CapEff")
        problems << "syrus-base-probe does not exit non-zero on failure" unless script.match?(/^exit "\$status"$/)
        problems
      end

      # Judge probe output ("ok <check>" / "fail <check>: <why>" lines) and exit
      # status. Missing, failed, unexpected-reporting, or malformed output all
      # make the image non-conformant.
      def evaluate(output, exit_status:, mode: FULL_MODE)
        problems = []
        checks = {}
        output.to_s.each_line do |line|
          case line.strip
          when /\Aok (\S+)\z/ then checks[$1] = :ok
          when /\Afail (\S+?):\s*(.*)\z/
            checks[$1] = :fail
            problems << Problem.new("check_failed", "#{$1}: #{$2.presence || "failed"}")
          when "" then next
          else problems << Problem.new("output_malformed", "unrecognised probe output #{line.strip.truncate(80).inspect}")
          end
        end

        (expected_checks(mode: mode) - checks.keys).each do |name|
          problems << Problem.new("check_missing", "probe did not report #{name}")
        end
        unless exit_status.to_i.zero?
          problems << Problem.new("probe_failed", "probe exited with status #{exit_status}")
        end
        problems << Problem.new("probe_no_output", "probe produced no output") if checks.empty?
        Result.new(problems, checks)
      end

      def evaluate!(output, exit_status:, mode: FULL_MODE)
        result = evaluate(output, exit_status: exit_status, mode: mode)
        raise NonConformant, result unless result.conformant?
        result
      end

      # Runs the probe for +reference+ (digest-pinned) under the real
      # confinement through +runner+, a callable taking the argv and returning
      # [stdout, exit_status]. Raises NonConformant unless every check passed.
      def verify_image!(reference, runner:, engine: "docker")
        output, status = runner.call(CoworkerBase.probe_command(reference, engine: engine))
        evaluate!(output, exit_status: status, mode: FULL_MODE)
      end

      # Verifies a published image: makes it local through the worker cache
      # (which also checks its ABI labels), then runs the confined probe
      # against its digest-pinned reference. Raises NonConformant on failure.
      def verify_published!(image, built_images: BuiltImages.new, runner: method(:run_confined))
        built_images.acquire(image) do |reference|
          verify_image!(reference, runner: runner)
        end
      end

      # Default runner: executes the argv through ProcessRunner and returns
      # [output, exit_status].
      def run_confined(argv, timeout: 120)
        capture = ProcessRunner.new(
          env: ENV.slice("PATH", "HOME", "DOCKER_HOST", "XDG_RUNTIME_DIR").compact,
          command: argv, mounts: ProcessRunner.probe_mounts, network: "prepare", timeout: timeout
        ).capture(limit: 64.kilobytes)
        result = capture.result
        [ capture.stdout.to_s + capture.stderr.to_s, result.timed_out? ? nil : (result.success? ? 0 : 1) ]
      end

      private

      def provider_keys = RuntimeAbi.providers.keys
      def support_tools = CoworkerBase.manifest.fetch("support_tools")

      # The probe names directories by basename: /workspace, /home/coworker.
      def directory_checks
        [ RuntimeAbi.contract.dig("filesystem", "workspace"), RuntimeAbi.contract.dig("filesystem", "provider_home") ]
          .map { |dir| "abi-dir-#{File.basename(dir)}" }
      end

      # Checks the script emits literally (not built from a loop variable).
      def fixed_check_names
        %w[abi-entrypoint identity-name abi-contract no-baked-credentials] + CONFINEMENT_CHECKS.reject { |n| n.start_with?("mount-writable") } +
          %w[mount-writable- abi-dir- provider- abi-path- tool-]
      end
    end
  end
end
