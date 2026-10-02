require "json"
require "tempfile"

module CredentialStore
  class SshExec
    SSH_PRIVATE_KEY_TYPE = "ssh_private_key".freeze
    TOOL_NAME = "credential_store_ssh_exec".freeze
    MAX_OUTPUT_BYTES = 64.kilobytes
    RISKY_COMMAND_PATTERN = /(?:\brm\s+-rf\b|\bdd\b|\bmkfs\b|\bshutdown\b|\breboot\b|\biptables\b|\bnft\b|\bchmod\s+-R\b|\bchown\s+-R\b)/i

    class Error < StandardError; end
    class InvalidTarget < Error; end
    class RiskyCommand < Error; end

    class << self
      attr_writer :runner

      def runner
        @runner || SshRunner
      end

      def call(context:, credential:, host:, user:, command:, port: nil, allow_unconstrained_host: false, allow_risky_command: false, connect_timeout: nil)
        new(
          context: context,
          credential: credential,
          host: host,
          user: user,
          command: command,
          port: port,
          allow_unconstrained_host: allow_unconstrained_host,
          allow_risky_command: allow_risky_command,
          connect_timeout: connect_timeout
        ).call
      end
    end

    def initialize(context:, credential:, host:, user:, command:, port:, allow_unconstrained_host:, allow_risky_command:, connect_timeout:)
      @context = context
      @credential = credential
      @host = host.to_s.strip
      @user = user.to_s.strip
      @command = command.to_s
      @port = normalized_port(port)
      @allow_unconstrained_host = allow_unconstrained_host == true
      @allow_risky_command = allow_risky_command == true
      @connect_timeout = normalized_timeout(connect_timeout)
    end

    def call
      validate_inputs!

      CredentialStore::Broker.with_credential_env(
        context: context,
        credential: credential,
        type: SSH_PRIVATE_KEY_TYPE,
        env_key: "SYRUS_CREDENTIAL_STORE_SSH_PAYLOAD",
        purpose: "ssh exec #{user}@#{host}",
        tool_name: TOOL_NAME,
        target: target
      ) do |credential_env, metadata|
        credential_metadata = metadata.fetch(:safe_metadata, {})
        validate_metadata!(credential_metadata, target_constraints: metadata.fetch(:target_constraints, {}))
        key_material = key_material_from(credential_env.fetch("SYRUS_CREDENTIAL_STORE_SSH_PAYLOAD"))

        with_temp_private_key(key_material.fetch(:private_key)) do |key_path|
          with_optional_askpass(key_material[:passphrase]) do |askpass_env|
            with_optional_known_hosts(credential_metadata) do |known_hosts_path|
              run_ssh(
                key_path: key_path,
                known_hosts_path: known_hosts_path,
                askpass_env: askpass_env,
                metadata: metadata,
                credential_metadata: credential_metadata,
                extra_secrets: key_material.values.compact
              )
            end
          end
        end
      end
    end

    private

    attr_reader :context, :credential, :host, :user, :command, :port, :allow_unconstrained_host, :allow_risky_command, :connect_timeout

    def validate_inputs!
      raise InvalidTarget, "host is required" if host.blank?
      raise InvalidTarget, "user is required" if user.blank?
      raise InvalidTarget, "command is required" if command.blank?
      raise RiskyCommand, "command requires explicit risky-command allowance" if risky_command? && !allow_risky_command
    end

    def validate_metadata!(metadata, target_constraints:)
      expected_host = metadata["host"].to_s.presence
      expected_user = metadata["username"].to_s.presence
      expected_port = metadata["port"].to_s.presence

      raise InvalidTarget, "credential host metadata does not match target" if expected_host && expected_host != host
      raise InvalidTarget, "credential username metadata does not match target" if expected_user && expected_user != user
      raise InvalidTarget, "credential port metadata does not match target" if expected_port && expected_port != port.to_s
      raise InvalidTarget, "credential has no host or known-host constraint" if unconstrained?(metadata, target_constraints) && !allow_unconstrained_host
    end

    def run_ssh(key_path:, known_hosts_path:, askpass_env:, metadata:, credential_metadata:, extra_secrets:)
      result = self.class.runner.call(
        env: ssh_env.merge(askpass_env),
        argv: ssh_argv(key_path: key_path, known_hosts_path: known_hosts_path, passphrase: askpass_env.present?)
      )

      payload = payload_for(result, metadata: metadata, credential_metadata: credential_metadata, known_hosts_enforced: known_hosts_path.present?)
      CredentialStore::Broker.redact(payload, extra_secrets: extra_secrets)
    rescue StandardError => e
      raise e.class, CredentialStore::Broker.redact(e.message, extra_secrets: extra_secrets)
    end

    def ssh_env
      {}
    end

    def ssh_argv(key_path:, known_hosts_path:, passphrase:)
      argv = [
        "ssh",
        "-i", key_path,
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=#{passphrase ? 'no' : 'yes'}",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=yes"
      ]
      argv.concat([ "-o", "UserKnownHostsFile=#{known_hosts_path}" ]) if known_hosts_path
      argv.concat([ "-o", "ConnectTimeout=#{connect_timeout}" ]) if connect_timeout
      argv.concat([ "-p", port.to_s ]) if port
      argv << "#{user}@#{host}"
      argv << command
      argv
    end

    def key_material_from(payload)
      parsed = JSON.parse(payload)
      private_key = parsed.fetch("private_key").to_s
      passphrase = parsed["passphrase"].to_s.presence
      raise InvalidTarget, "private_key is required in SSH credential payload" if private_key.blank?

      { private_key: private_key, passphrase: passphrase }
    rescue JSON::ParserError
      { private_key: payload.to_s, passphrase: nil }
    rescue KeyError
      raise InvalidTarget, "private_key is required in SSH credential payload"
    end

    def with_temp_private_key(private_key)
      tempfile = Tempfile.new("syrus-ssh-private-key")
      tempfile.write(private_key)
      tempfile.flush
      tempfile.close
      File.chmod(0o600, tempfile.path)

      yield(tempfile.path)
    ensure
      tempfile&.unlink
    end

    def with_optional_askpass(passphrase)
      return yield({}) if passphrase.blank?

      tempfile = Tempfile.new("syrus-ssh-askpass")
      tempfile.write("#!/bin/sh\nprintf '%s' \"$SYRUS_CREDENTIAL_STORE_SSH_PASSPHRASE\"\n")
      tempfile.flush
      tempfile.close
      File.chmod(0o700, tempfile.path)

      yield({
        "DISPLAY" => ENV.fetch("DISPLAY", ":0"),
        "SSH_ASKPASS" => tempfile.path,
        "SSH_ASKPASS_REQUIRE" => "force",
        "SYRUS_CREDENTIAL_STORE_SSH_PASSPHRASE" => passphrase
      })
    ensure
      tempfile&.unlink
    end

    def with_optional_known_hosts(metadata)
      known_host = metadata["known_host"].to_s.presence
      return yield(nil) unless known_host

      tempfile = Tempfile.new("syrus-ssh-known-hosts")
      tempfile.write("#{known_host}\n")
      tempfile.flush
      tempfile.close
      File.chmod(0o600, tempfile.path)

      yield(tempfile.path)
    ensure
      tempfile&.unlink
    end

    def payload_for(result, metadata:, credential_metadata:, known_hosts_enforced:)
      {
        ok: result.success?,
        status: result.status.to_i,
        stdout: truncate(result.stdout),
        stderr: truncate(result.stderr),
        target: { host: host, user: user, port: port }.compact,
        credential: metadata.except(:safe_metadata),
        known_hosts_enforced: known_hosts_enforced,
        fingerprint: credential_metadata["fingerprint"]
      }.compact
    end

    def truncate(value)
      Mcp::Tools.truncate_text(Mcp::Tools.utf8(value), MAX_OUTPUT_BYTES)
    end

    def target
      { host: host, user: user, port: port }.compact
    end

    def unconstrained?(metadata, target_constraints)
      allowed_hosts = Array(target_constraints["allowed_hosts"])
      metadata["host"].blank? && metadata["known_host"].blank? && allowed_hosts.empty?
    end

    def risky_command?
      command.match?(RISKY_COMMAND_PATTERN)
    end

    def normalized_port(value)
      return nil if value.blank?

      Integer(value).tap do |integer|
        raise InvalidTarget, "port must be between 1 and 65535" unless integer.between?(1, 65_535)
      end
    rescue ArgumentError
      raise InvalidTarget, "port must be between 1 and 65535"
    end

    def normalized_timeout(value)
      return nil if value.blank?

      Integer(value).tap do |integer|
        raise InvalidTarget, "connect_timeout must be between 1 and 120" unless integer.between?(1, 120)
      end
    rescue ArgumentError
      raise InvalidTarget, "connect_timeout must be between 1 and 120"
    end
  end
end
