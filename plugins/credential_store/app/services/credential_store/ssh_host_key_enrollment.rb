module CredentialStore
  class SshHostKeyEnrollment
    TIMEOUT_SECONDS = 10
    class ProbeFailed < SshExec::Error; end
    class ProbeTimedOut < ProbeFailed; end

    class << self
      attr_writer :runner
      def runner = @runner || SshRunner

      def probe!(host:, port:)
        host = host.to_s.strip
        raise SshExec::InvalidTarget, "host must be a hostname or IP address" unless SshHostKey.valid_host?(host)
        port = SshHostKey.normalize_port!(port)
        result = runner.call(env: {}, argv: [ "ssh-keyscan", "-T", "5", "-p", port.to_s, "--", host ], timeout: TIMEOUT_SECONDS)
        raise ProbeTimedOut, "SSH host-key probe timed out" if result.status.to_i == 124
        raise ProbeFailed, "Could not retrieve an SSH host key from #{host}:#{port}" unless result.success?
        keys = result.stdout.each_line.filter_map do |line|
          next if line.lstrip.start_with?("#") || line.blank?
          SshHostKey.parse!(line: line, host: host, port: port)
        rescue SshExec::InvalidTarget
          nil
        end
        keys.min_by { |key| SshHostKey::KEY_TYPES.index(key.key_type) } || raise(ProbeFailed, "The SSH server returned no supported host keys")
      end

      def manual!(host:, port:, known_host:) = SshHostKey.parse!(line: known_host, host: host.to_s.strip, port: port)
    end
  end
end
