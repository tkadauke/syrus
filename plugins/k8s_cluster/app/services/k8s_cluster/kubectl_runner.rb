require "timeout"

module K8sCluster
  class KubectlRunner
    DEFAULT_TIMEOUT_SECONDS = 30

    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.to_i.zero?
    end

    def self.call(env:, argv:, timeout: DEFAULT_TIMEOUT_SECONDS)
      new(env: env, argv: argv, timeout: timeout).call
    end

    def initialize(env:, argv:, timeout:)
      @env = env
      @argv = argv
      @timeout = timeout
    end

    def call
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      pid = Process.spawn(env, *argv, out: stdout_writer, err: stderr_writer, pgroup: true)
      stdout_writer.close
      stderr_writer.close
      stdout_thread = Thread.new { stdout_reader.read }
      stderr_thread = Thread.new { stderr_reader.read }
      status = wait_with_timeout(pid)

      Result.new(stdout: stdout_thread.value, stderr: stderr_thread.value, status: status.exitstatus || 1)
    rescue Timeout::Error
      status = terminate(pid)
      Result.new(stdout: stdout_thread&.value.to_s, stderr: "#{stderr_thread&.value}kubectl timed out after #{timeout} seconds\n", status: status&.exitstatus || 124)
    ensure
      [ stdout_writer, stderr_writer, stdout_reader, stderr_reader ].each { |io| io&.close unless io.closed? }
    end

    private

    attr_reader :env, :argv, :timeout

    def wait_with_timeout(pid)
      Timeout.timeout(timeout) { Process.wait2(pid).last }
    end

    def terminate(pid)
      Process.kill("TERM", -pid)
      Timeout.timeout(1) { Process.wait2(pid).last }
    rescue Timeout::Error
      Process.kill("KILL", -pid)
      Process.wait2(pid).last
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
