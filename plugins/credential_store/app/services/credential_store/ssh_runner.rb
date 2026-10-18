module CredentialStore
  class SshRunner
    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.to_i.zero?
    end

    def self.call(env:, argv:)
      current_run = Thread.current[:syrus_current_run]
      capture = ProcessRunner.new(
        env: env, command: argv, mounts: ProcessRunner.mounts(Dir.pwd), network: "agent",
        timeout: 10.minutes, kind: "chat_shell_command", run: current_run, workflow: current_run&.workflow,
        chat_session: Thread.current[:syrus_current_chat_session]
      ).capture
      Result.new(stdout: capture.stdout, stderr: capture.stderr, status: capture.result.exit_status || 1)
    end
  end
end
