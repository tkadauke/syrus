# frozen_string_literal: true

require "open3"
require "shellwords"

module Deploy
  # The single door to every external command, and the only place a deploy can
  # change anything outside this process.
  #
  # Reads and writes are separate methods because the caller knows which it is
  # making. The bash implementation could not: it intercepted deploys by
  # shadowing `kubectl` as a function, so the only thing it had to classify on
  # was argv, and it had to guess a verb out of a flag-laden argument list and
  # treat everything unrecognised as a write. Declaring intent at the call site
  # removes the guess.
  #
  # The verb allowlist survives anyway, inverted into an assertion: `read` with
  # a mutating verb raises. Intent and argv now have to agree, so a `read` that
  # says `delete` is a bug caught in a spec rather than a mutation that escapes
  # a dry run -- which is strictly more than the guess could ever do.
  class Shell
    # Verbs that only observe. Nothing outside this set may travel through
    # `read`.
    KUBECTL_READ_VERBS = %w[
      api-resources api-versions auth cluster-info config describe diff events
      explain get logs top version
    ].freeze

    # Everything kubectl can be asked to do. A verb in neither list is
    # unrecognised, and an unrecognised verb is assumed to mutate -- the first
    # new subcommand someone reaches for must not be the one that slips through.
    KUBECTL_WRITE_VERBS = %w[
      annotate apply attach autoscale cordon cp create delete drain edit exec
      expose label patch port-forward replace rollout run scale set taint
      uncordon wait
    ].freeze

    Result = Struct.new(:argv, :stdout, :stderr, :status, keyword_init: true) do
      def success?
        status.zero?
      end

      def out
        stdout.to_s
      end

      def command
        argv.join(" ")
      end
    end

    attr_reader :reporter, :clock

    def initialize(reporter:, clock: Clock.new, dry_run: false, stream: nil, chdir: Dir.pwd)
      @reporter = reporter
      @clock = clock
      @dry_run = dry_run
      @chdir = chdir
      @stream = stream
      @recorded = []
    end

    def dry_run?
      @dry_run
    end

    # Observations run in both modes. The deploy derives nearly everything it
    # does from live cluster state -- the migration Job is built from the
    # running web deployment, the pre-pull DaemonSet copies the compute
    # DaemonSet's placement, Flux's image overrides are snapshotted before they
    # are replaced -- so a dry run that could not read would describe a deploy
    # against a cluster it never looked at. That is worse than no answer,
    # because it looks like one.
    def read(argv, env: {}, stdin: nil, label: nil)
      assert_read_only!(argv)
      execute(argv, env: env, stdin: stdin, label: label)
    end

    # Mutations run only for real. In a dry run they are recorded and reported
    # as having succeeded, so the phases downstream behave as they would on a
    # cluster that accepted them.
    def write(argv, env: {}, stdin: nil, label: nil)
      if dry_run?
        record(argv)
        return Result.new(argv: argv, stdout: "", stderr: "", status: 0)
      end

      execute(argv, env: env, stdin: stdin, label: label)
    end

    # Long builds and rollout waits have to show their output as it happens;
    # capturing ten minutes of `docker build` and printing it at the end turns
    # a visibly-working deploy into a visibly-hung one.
    def stream_write(argv, env: {})
      if dry_run?
        record(argv)
        return Result.new(argv: argv, stdout: "", stderr: "", status: 0)
      end

      system(stringify(env), *argv, chdir: @chdir)
      Result.new(argv: argv, stdout: "", stderr: "", status: $?&.exitstatus || 1)
    end

    # Calls into bin/docker-image-lib, which stays bash because
    # bin/publish-image, bin/build-local-image and bin/compose-up share it.
    # Rewriting it here would either fork that logic or drag three more scripts
    # into this change; a sourced-and-called shim keeps one implementation of
    # "how Syrus builds an image" and costs one process.
    #
    # `mode` is the same read/write declaration everything else makes.
    # `:stream` is a write whose output has to appear as it happens -- a build
    # that prints nothing for ten minutes looks hung.
    def docker_lib(function, *args, env: {}, mode: :stream)
      argv = [ "bash", "-c", <<~SH, function, *args.map(&:to_s) ]
        set -euo pipefail
        . bin/docker-image-lib
        #{function} "$@"
      SH

      case mode
      when :read then read(argv, env: env, label: function)
      when :write then write(argv, env: env)
      else stream_write(argv, env: env)
      end
    end

    # Commands recorded by this run, newest last. `--dry-run` exists to answer
    # one question mechanically -- what sequence of commands does a deploy
    # actually run? -- so the stream is the artifact, and diffing it against
    # another implementation's is how a rewrite proves what it preserved.
    attr_reader :recorded

    private

    def record(argv)
      line = "DRYRUN #{argv.join(" ")}"
      @recorded << line
      sink.puts(line)
      sink.flush
      line
    end

    def sink
      @sink ||= @stream || $stdout
    end

    def execute(argv, env:, stdin:, label:)
      stdout, stderr, status = Open3.capture3(stringify(env), *argv, stdin_data: stdin.to_s, chdir: @chdir)
      Result.new(argv: argv, stdout: stdout, stderr: stderr, status: status.exitstatus || 1)
    rescue Errno::ENOENT => e
      raise Failure.new("#{label || argv.first}: #{e.message}")
    end

    def stringify(env)
      env.to_h { |key, value| [ key.to_s, value&.to_s ] }
    end

    def assert_read_only!(argv)
      tool = File.basename(argv.first.to_s)
      return unless tool == "kubectl"

      verb = kubectl_verb(argv)
      return if KUBECTL_READ_VERBS.include?(verb)

      raise Failure.new(
        "internal: kubectl #{verb || "<none>"} was issued as a read",
        detail: argv.join(" ")
      )
    end

    # Global flags take values, so the verb is not simply the first bare
    # argument: `kubectl -n syrus delete job/foo` must not read its verb as
    # "syrus". Scan for the first argument that is a verb kubectl actually has.
    def kubectl_verb(argv)
      argv.drop(1).find { |arg| KUBECTL_READ_VERBS.include?(arg) || KUBECTL_WRITE_VERBS.include?(arg) }
    end
  end
end
