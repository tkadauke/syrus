require "timeout"

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
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      pid = Process.spawn(env, *argv, out: stdout_writer, err: stderr_writer, pgroup: true, unsetenv_others: true)
      stdout_writer.close
      stderr_writer.close
      stdout_thread = Thread.new { read_bounded(stdout_reader) }
      stderr_thread = Thread.new { read_bounded(stderr_reader) }
      status = wait_with_timeout(pid)

      Result.new(stdout: stdout_thread.value, stderr: stderr_thread.value, status: status.exitstatus || 1)
    rescue Timeout::Error
      status = terminate(pid)
      Result.new(stdout: stdout_thread&.value.to_s, stderr: "#{stderr_thread&.value}kubectl timed out after #{timeout} seconds\n", status: status&.exitstatus || 124)
    ensure
      [ stdout_writer, stderr_writer, stdout_reader, stderr_reader ].each { |io| io&.close unless io.closed? }
    end

    private

    attr_reader :env, :argv, :timeout, :max_output_bytes

    def read_bounded(io)
      output = +""
      while (chunk = io.readpartial(16.kilobytes))
        remaining = max_output_bytes + 1 - output.bytesize
        output << chunk.byteslice(0, remaining) if remaining.positive?
      end
      output
    rescue EOFError
      output
    end

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
