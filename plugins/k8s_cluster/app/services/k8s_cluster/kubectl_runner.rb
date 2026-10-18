module K8sCluster
  class KubectlRunner
    DEFAULT_TIMEOUT_SECONDS = 30
    DEFAULT_MAX_OUTPUT_BYTES = 64.kilobytes

    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.to_i.zero?
    end

    def self.call(env:, argv:, timeout: DEFAULT_TIMEOUT_SECONDS, max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES)
      new(env: env, argv: argv, timeout: timeout, max_output_bytes: max_output_bytes).call
    end

    def initialize(env:, argv:, timeout:, max_output_bytes:)
      @env = env
      @argv = argv
      @timeout = timeout
      @max_output_bytes = max_output_bytes
    end

    def call
      capture = ProcessRunner.new(
        env: env, command: argv, mounts: ProcessRunner.mounts(Dir.pwd), network: "agent",
        timeout: timeout, kind: "chat_shell_command", run: Thread.current[:syrus_current_run],
        workflow: Thread.current[:syrus_current_run]&.workflow,
        chat_session: Thread.current[:syrus_current_chat_session]
      ).capture(limit: max_output_bytes + 1)
      stderr = capture.stderr
      stderr += "kubectl timed out after #{timeout} seconds\n" if capture.result.timed_out?
      status = capture.result.timed_out? ? 124 : (capture.result.exit_status || 1)
      Result.new(stdout: capture.stdout, stderr: stderr, status: status)
    end

    private

    attr_reader :env, :argv, :timeout, :max_output_bytes

  end
end
