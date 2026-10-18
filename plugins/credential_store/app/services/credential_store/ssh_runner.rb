require "open3"
require "timeout"

module CredentialStore
  class SshRunner
    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.to_i.zero?
    end

    def self.call(env:, argv:, timeout: nil)
      stdout, stderr, status, timed_out = +"", +"", nil, false
      Open3.popen3(env, *argv) do |stdin, out, err, wait_thread|
        stdin.close
        readers = [ Thread.new { stdout << out.read }, Thread.new { stderr << err.read } ]
        begin
          timeout ? Timeout.timeout(timeout) { status = wait_thread.value } : status = wait_thread.value
        rescue Timeout::Error
          timed_out = true
          Process.kill("TERM", wait_thread.pid)
          status = wait_thread.value
        ensure
          readers.each(&:join)
        end
      end
      Result.new(stdout: stdout, stderr: stderr, status: timed_out ? 124 : (status&.exitstatus || 1))
    end
  end
end
