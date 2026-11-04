require "json"

module Diagnostics
  # Runs an on-demand diagnostic inside a live process, triggered by a signal
  # and parameterised by a file. Nothing is exposed over HTTP.
  #
  # Why a signal rather than an endpoint:
  #
  # - The processes worth diagnosing are Solid Queue workers. An endpoint
  #   executes in the web pod and would inspect the wrong process entirely.
  # - A pod runs several Ruby processes (supervisor, runs worker, merges
  #   worker, dispatcher). A signal addresses exactly one pid. A shared trigger
  #   file would be noticed by all of them at once, and several simultaneous
  #   whole-heap walks are precisely how you OOM a pod that is already near its
  #   memory limit.
  # - Sending a signal requires a shell in the container. That *is* the access
  #   gate: no port, no listener, no token that could be used from outside.
  #
  # One signal, because a signal carries no arguments and reserving a second
  # one to mean "the other thing" does not scale past two. The request file
  # names the diagnostic instead, so new ones are a `register` call rather than
  # another signal.
  #
  #   cat > $SYRUS_DATA_ROOT/diagnostics/request.json <<'JSON'
  #   {"kind": "heap_histogram", "top_n": 50}
  #   JSON
  #   kill -USR2 <pid>
  #
  # Output is written beside the request as
  # <kind>-<pid>-<timestamp>.<extension>, and the process logs where it went.
  class SignalTrigger
    SIGNAL = "USR2".freeze
    REQUEST_BASENAME = "request.json".freeze
    DIRECTORY_NAME = "diagnostics".freeze

    # What a registered diagnostic receives. `options` is the parsed request
    # file; `path_for` builds an output path in the diagnostics directory and
    # creates its parent, so a handler never has to know the layout.
    Request = Struct.new(:kind, :options, :pid, :started_at, keyword_init: true) do
      def path_for(extension)
        path = File.join(SignalTrigger.directory,
          "#{kind}-#{pid}-#{started_at.strftime('%Y%m%dT%H%M%S')}.#{extension}")
        FileUtils.mkdir_p(File.dirname(path))
        path
      end

      def fetch_integer(key, default:, max:)
        value = Integer(options[key.to_s] || default, exception: false) || default
        value.clamp(1, max)
      end
    end

    class << self
      def registry = @registry ||= {}

      # A diagnostic returns either a Hash -- written as pretty JSON to
      # `request.path_for("json")` -- or a path it wrote itself, for output
      # that should not be built in memory first.
      def register(kind, &block)
        registry[kind.to_s] = block
      end

      def install!
        return false if installed?

        trap(SIGNAL) { request }
        @installed = true
      rescue ArgumentError, TypeError
        # A platform without this signal is not a reason to fail boot.
        false
      end

      def installed? = @installed == true

      # Runs in a trap context, so it does the minimum: a guard and a thread.
      # Signal dispositions survive fork but threads do not, so spawning per
      # signal is what keeps this working in Solid Queue's forked children
      # without a supervisor hook -- and leaves nothing running when idle.
      def request
        return false if @running

        @running = true
        Thread.new do
          run
        ensure
          @running = false
        end
        true
      rescue StandardError
        @running = false
        false
      end

      def run(now: Time.now)
        options = read_request
        kind = options["kind"].to_s
        handler = registry[kind]
        unless handler
          log("unknown diagnostic #{kind.inspect}; known kinds: #{registry.keys.sort.join(', ')}")
          return nil
        end

        request = Request.new(kind: kind, options: options, pid: Process.pid, started_at: now)
        result = handler.call(request)
        path = finish(request, result)
        log("#{kind} wrote #{path}") if path
        path
      rescue StandardError => e
        log("diagnostic failed: #{e.class}: #{e.message}")
        nil
      end

      def directory
        File.join(ENV.fetch("SYRUS_DATA_ROOT", File.expand_path("~/.syrus")), DIRECTORY_NAME)
      end

      def request_path = File.join(directory, REQUEST_BASENAME)

      private

      def finish(request, result)
        case result
        when Hash
          path = request.path_for("json")
          File.write(path, JSON.pretty_generate(result))
          path
        when String then result
        end
      end

      # Parameters only; the signal says "go". Missing or malformed files are
      # not an error -- a diagnostic with sane defaults should still run, and a
      # half-written file should not abort the capture you were trying to take.
      def read_request
        parsed = JSON.parse(File.read(request_path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end

      def log(message)
        Rails.logger.info("[Diagnostics] #{message}")
      rescue StandardError
        warn("[Diagnostics] #{message}")
      end
    end
  end
end
