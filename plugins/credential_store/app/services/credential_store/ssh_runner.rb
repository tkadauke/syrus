module CredentialStore
  class SshRunner
    KILL_GRACE_SECONDS = 0.25

    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.to_i.zero?
    end

    def self.call(env:, argv:, timeout: nil)
      current_run = Thread.current[:syrus_current_run]
      capture = ProcessRunner.new(
        env: env, command: argv, mounts: ProcessRunner.mounts(Dir.pwd), network: "agent",
        timeout: timeout || 10.minutes, kind: "chat_shell_command", run: current_run, workflow: current_run&.workflow,
        chat_session: Thread.current[:syrus_current_chat_session], kill_grace_seconds: KILL_GRACE_SECONDS
      ).capture
      status = capture.result.timed_out? ? 124 : (capture.result.exit_status || 1)
      Result.new(stdout: capture.stdout, stderr: capture.stderr, status: status)
    end
  end
end
