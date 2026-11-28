class WorkerEnvironmentSmoke
  # Runs one check command the way Steps::Prepare runs a prepare command:
  # through ProcessRunner, on the "prepare" network profile, with exactly the
  # forwarded environment. A check that ran any other way could pass where the
  # work it vouches for fails. This is also the seam specs stub: no check
  # reaches a real process through anything else.
  #
  # bin/worker-environment-smoke, which runs without Rails, supplies its own
  # shell with the same interface.
  class Shell
    Result = Data.define(:status, :output, :exit_status) do
      def success? = status == "ok"
    end

    OUTPUT_LIMIT = 64 * 1024

    def run(argv, env: {}, chdir: nil, timeout: 10)
      capture = ProcessRunner.new(
        env: env, command: argv, mounts: chdir ? ProcessRunner.mounts(chdir) : ProcessRunner.probe_mounts,
        network: "prepare", timeout: timeout, kind: "runtime_probe"
      ).capture(limit: OUTPUT_LIMIT)
      output = "#{capture.stdout}#{capture.stderr}"
      return Result.new(status: "ok", output: output, exit_status: 0) if capture.success?

      exit_status = capture.result.exit_status
      Result.new(status: self.class.failure_status(timed_out: capture.result.timed_out?, exit_status: exit_status),
        output: output, exit_status: exit_status)
    rescue Errno::ENOENT
      Result.new(status: "not_found", output: "", exit_status: 127)
    rescue Errno::EACCES
      Result.new(status: "not_executable", output: "", exit_status: 126)
    end

    def self.failure_status(timed_out:, exit_status:)
      return "timed_out" if timed_out
      return "not_found" if exit_status == 127
      return "not_executable" if exit_status == 126

      "failed"
    end
  end
end
