require "shellwords"
require "tempfile"
require "digest"

module CredentialStore
  class SshExec
    SSH_PRIVATE_KEY_TYPE = "ssh_private_key".freeze
    TOOL_NAME = "credential_store_ssh_exec".freeze
    MAX_OUTPUT_BYTES = 64.kilobytes

    class Error < StandardError; end
    class InvalidTarget < Error; end
    class RiskyCommand < Error; end
    class OperatorConfirmationRequired < Error; end

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
      @port_input = port
      @allow_unconstrained_host = allow_unconstrained_host == true
      @allow_risky_command = allow_risky_command == true
      @connect_timeout_input = connect_timeout
    end

    def call
      CredentialStore::Broker.with_credential_env(
        context: context,
        credential: credential,
        type: SSH_PRIVATE_KEY_TYPE,
        env_key: "SYRUS_CREDENTIAL_STORE_SSH_PAYLOAD",
        purpose: "ssh exec #{user}@#{host}",
        tool_name: TOOL_NAME,
        target: target,
        credential_validator: method(:validate_credential_attempt!),
        attempt_metadata: command_metadata
      ) do |credential_env, metadata|
        credential_metadata = metadata.fetch(:safe_metadata, {})
        key_material = SshKeyMaterial.from_payload(credential_env.fetch("SYRUS_CREDENTIAL_STORE_SSH_PAYLOAD"))

        with_temp_private_key(key_material.private_key) do |key_path|
          with_optional_askpass(key_material.passphrase) do |askpass_env|
            with_optional_known_hosts(credential_metadata) do |known_hosts_path|
              run_ssh(
                key_path: key_path,
                known_hosts_path: known_hosts_path,
                askpass_env: askpass_env,
                metadata: metadata,
                credential_metadata: credential_metadata,
                extra_secrets: key_material.secrets
              )
            end
          end
        end
      end
    end

    private

    attr_reader :context, :credential, :host, :user, :command, :port, :allow_unconstrained_host, :allow_risky_command, :connect_timeout

    def validate_inputs!
      @port = normalized_port(@port_input)
      @connect_timeout = normalized_timeout(@connect_timeout_input)
      raise InvalidTarget, "host is required" if host.blank?
      raise InvalidTarget, "user is required" if user.blank?
      raise InvalidTarget, "command is required" if command.blank?
      raise OperatorConfirmationRequired, "chat SSH calls cannot self-authorize risky commands" if context.chat? && allow_risky_command
      raise OperatorConfirmationRequired, "chat SSH calls cannot self-authorize unconstrained hosts" if context.chat? && allow_unconstrained_host
      raise RiskyCommand, "command requires explicit risky-command allowance" if risky_command? && !allow_risky_command
    end

    def validate_credential_attempt!(credential)
      validate_inputs!
      credential_denial_reason(credential)
    end

    def credential_denial_reason(credential)
      metadata = credential.safe_metadata.to_h
      target_constraints = credential.target_constraints.to_h
      expected_host = metadata["host"].to_s.presence
      expected_user = metadata["username"].to_s.presence
      expected_port = metadata["port"].to_s.presence

      return "credential host metadata does not match target" if expected_host && expected_host != host
      return "credential username metadata does not match target" if expected_user && expected_user != user
      return "credential port metadata does not match target" if expected_port && expected_port != port.to_s
      return "credential has no host or known-host constraint" if unconstrained?(metadata, target_constraints) && !allow_unconstrained_host

      nil
    end

    def run_ssh(key_path:, known_hosts_path:, askpass_env:, metadata:, credential_metadata:, extra_secrets:)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = begin
        self.class.runner.call(
          env: ssh_env.merge(askpass_env),
          argv: ssh_argv(key_path: key_path, known_hosts_path: known_hosts_path, passphrase: askpass_env.present?)
        )
      rescue StandardError => e
        record_completion!(metadata, nil, started_at, error: e)
        raise e.class, CredentialStore::Broker.redact(e.message, extra_secrets: extra_secrets)
      end

      record_completion!(metadata, result.status.to_i, started_at)
      payload = payload_for(result, metadata: metadata, credential_metadata: credential_metadata, known_hosts_enforced: known_hosts_path.present?)
      CredentialStore::Broker.redact(payload, extra_secrets: extra_secrets)
    end

    def record_completion!(lease_metadata, exit_status, started_at, error: nil)
      credential_record = Credential.find(lease_metadata.fetch(:credential_id))
      lease_id = lease_metadata.fetch(:lease_id)
      lease_event = credential_record.access_events.find_by(action: "lease", result: "allowed", lease_id: lease_id)
      raise ActiveRecord::RecordNotFound, "lease event not found" unless lease_event
      CredentialAccessEvent.record!(
        credential: credential_record, lease_event: lease_event,
        user: context.user, repository: context.repository, job: context.job,
        workflow: context.workflow, run: context.run, chat_session: context.chat_session,
        surface: context.run? ? "workflow" : context.surface.to_s,
        tool_name: TOOL_NAME, action: "use", purpose: "ssh exec #{user}@#{host}",
        result: error || exit_status != 0 ? "failed" : "allowed",
        metadata: Redaction.scrub_object(command_metadata, credentials: [ credential_record ]).merge(
          lease_id: lease_id, exit_status: exit_status,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round,
          error_class: error&.class&.name
        ).compact
      )
    end

    def command_metadata
      { command_sha256: Digest::SHA256.hexdigest(command), command: command.truncate(500) }
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
      RiskyCommandClassifier.risky?(command)
    end

    class RiskyCommandClassifier
      RISKY_COMMANDS = %w[dd shutdown reboot nft].freeze
      COMMAND_SEPARATORS = %w[; & |].freeze
      ASSIGNMENT_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*=/.freeze
      SHELL_EVALUATION_PATTERN = /(?:\$\(|`|\A\()/.freeze

      class << self
        def risky?(command)
          tokens = Shellwords.split(command.to_s.gsub(/([;&|])/, ' \1 '))
          return true if tokens.empty?
          return true if tokens.any? { |token| shell_evaluation_token?(token) }
          return true if tokens.any? { |token| nested_command_fragment?(token) }

          command_segments(tokens).any? { |segment| risky_segment?(segment) }
        rescue ArgumentError
          true
        end

        private

        def command_segments(tokens)
          tokens.each_with_object([ [] ]) do |token, segments|
            if COMMAND_SEPARATORS.include?(token)
              segments << []
            else
              segments.last << token
            end
          end.reject(&:empty?)
        end

        def risky_segment?(segment)
          segment.each_with_index.any? do |word, index|
            next false if word.match?(ASSIGNMENT_PATTERN) || flag?(word)

            risky_invocation?(command_name(word), segment[(index + 1)..])
          end
        end

        def shell_evaluation_token?(token)
          token.match?(SHELL_EVALUATION_PATTERN)
        end

        def nested_command_fragment?(token)
          token.match?(/\s/) && risky?(token)
        end

        def risky_invocation?(executable, arguments)
          return false unless executable
          return true if risky_command_name?(executable)

          flags = Array(arguments).select { |word| flag?(word) }
          case executable
          when "rm"
            rm_force?(flags) && rm_recursive?(flags)
          when "chmod", "chown"
            recursive?(flags)
          else
            false
          end
        end

        def risky_command_name?(executable)
          RISKY_COMMANDS.include?(executable) ||
            executable == "mkfs" ||
            executable.start_with?("mkfs.") ||
            executable == "iptables" ||
            executable.start_with?("iptables-")
        end

        def command_name(word)
          File.basename(word.to_s).downcase.presence
        end

        def flag?(word)
          word.to_s.start_with?("-") && word != "-"
        end

        def rm_force?(flags)
          flags.any? { |flag| long_flag?(flag, "force") || short_flag?(flag, "f") }
        end

        def rm_recursive?(flags)
          flags.any? { |flag| long_flag?(flag, "recursive") || short_flag?(flag, "r") || short_flag?(flag, "R") }
        end

        def recursive?(flags)
          flags.any? { |flag| long_flag?(flag, "recursive") || short_flag?(flag, "R") }
        end

        def long_flag?(flag, name)
          flag == "--#{name}" || flag.start_with?("--#{name}=")
        end

        def short_flag?(flag, letter)
          flag.start_with?("-") && !flag.start_with?("--") && flag.delete_prefix("-").include?(letter)
        end
      end
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
