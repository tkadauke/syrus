require "open3"
require "timeout"

module CredentialStore
  class SshRunner
    TERM_GRACE_SECONDS = 0.25
    KILL_GRACE_SECONDS = 1
    READER_GRACE_SECONDS = 0.25

    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.to_i.zero?
    end

    def self.call(env:, argv:, timeout: nil)
      stdout, stderr, status, timed_out = +"", +"", nil, false
      Open3.popen3(env, *argv, pgroup: true) do |stdin, out, err, wait_thread|
        stdin.close
        readers = [ Thread.new { stdout << out.read }, Thread.new { stderr << err.read } ]
        begin
          timeout ? Timeout.timeout(timeout) { status = wait_thread.value } : status = wait_thread.value
        rescue Timeout::Error
          timed_out = true
          signal_group("TERM", wait_thread.pid)
          status = wait_for(wait_thread, TERM_GRACE_SECONDS)
          unless status
            signal_group("KILL", wait_thread.pid)
            status = wait_for(wait_thread, KILL_GRACE_SECONDS)
          end
        ensure
          readers.zip([ out, err ]).each do |reader, io|
            reader.join(READER_GRACE_SECONDS)
            next unless reader.alive?

            io.close unless io.closed?
            reader.join(READER_GRACE_SECONDS)
            reader.kill if reader.alive?
          end
        end
      end
      Result.new(stdout: stdout, stderr: stderr, status: timed_out ? 124 : (status&.exitstatus || 1))
    end

    def self.wait_for(wait_thread, seconds)
      Timeout.timeout(seconds) { wait_thread.value }
    rescue Timeout::Error
      nil
    end

    def self.signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    private_class_method :wait_for, :signal_group
  end
end
