require "tempfile"

module CredentialStore
  class Broker
    DEFAULT_LEASE_TTL = 2.minutes
    FILE_PREFIX = "syrus-credential-".freeze

    class Error < StandardError; end
    class NotFound < Error; end
    class Denied < Error
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("credential access denied: #{reason}")
      end
    end
    class ExecutionError < Error; end

    class << self
      def with_credential_file(context:, credential:, type:, purpose:, tool_name: nil, target: {}, expires_in: DEFAULT_LEASE_TTL)
        new(context: context, credential_ref: credential, type: type, purpose: purpose, tool_name: tool_name, target: target, expires_in: expires_in)
          .with_file { |path, metadata| yield path, metadata }
      end

      def with_credential_env(context:, credential:, type:, env_key:, purpose:, tool_name: nil, target: {}, expires_in: DEFAULT_LEASE_TTL)
        new(context: context, credential_ref: credential, type: type, purpose: purpose, tool_name: tool_name, target: target, expires_in: expires_in)
          .with_env(env_key: env_key) { |env, metadata| yield env, metadata }
      end

      def redact(value, credentials: [], extra_secrets: [])
        Redaction.scrub_object(value, credentials: credentials, extra_secrets: extra_secrets)
      end
    end

    def initialize(context:, credential_ref:, type:, purpose:, tool_name:, target:, expires_in:)
      @context = context
      @credential_ref = credential_ref
      @type = type.to_s
      @purpose = purpose.to_s
      @tool_name = tool_name.to_s.presence
      @target = (target || {}).to_h.symbolize_keys
      @expires_in = expires_in
    end

    def with_file
      credential = authorized_credential!
      lease = lease_for(credential)
      tempfile = Tempfile.new(FILE_PREFIX, binmode: true)
      tempfile.write(credential.payload)
      tempfile.flush
      tempfile.close
      File.chmod(0o600, tempfile.path)

      yield_with_redaction(credential) { yield tempfile.path, metadata_for(credential, lease) }
    ensure
      tempfile&.unlink
    end

    def with_env(env_key:)
      credential = authorized_credential!
      lease = lease_for(credential)
      env = { env_key.to_s => credential.payload }

      yield_with_redaction(credential) { yield env, metadata_for(credential, lease) }
    ensure
      env&.clear
    end

    private

    attr_reader :context, :credential_ref, :type, :purpose, :tool_name, :target, :expires_in

    def authorized_credential!
      credential = resolve_credential
      raise NotFound, "credential not found" unless credential

      denial_reason = denial_reason_for(credential)
      if denial_reason
        record_event!(credential, result: "denied", denial_reason: denial_reason)
        raise Denied, denial_reason
      end

      record_event!(credential, result: "allowed")
      credential
    end

    def resolve_credential
      relation = Credential.all
      relation = relation.where(id: credential_ref) if integer_ref?
      relation = relation.where(name: credential_ref.to_s) unless integer_ref?
      relation.detect { |candidate| candidate.scope_policy.usable_by?(candidate, context) }
    end

    def integer_ref?
      credential_ref.is_a?(Integer) || credential_ref.to_s.match?(/\A\d+\z/)
    end

    def denial_reason_for(credential)
      return "credential revoked" if credential.revoked?
      return "credential expired" if credential.expired?
      return "credential type mismatch" unless credential.credential_type == type
      return "surface not allowed" unless surface_allowed?(credential)
      return "tool not allowed" unless tool_allowed?(credential)

      target_denial_reason(credential)
    end

    def surface_allowed?(credential)
      allowed = Array(credential.allowed_surfaces).map(&:to_s)
      allowed.empty? || allowed.include?(event_surface)
    end

    def tool_allowed?(credential)
      allowed = Array(credential.allowed_tools).map(&:to_s)
      allowed.empty? || (tool_name.present? && allowed.include?(tool_name))
    end

    def target_denial_reason(credential)
      credential.target_constraints.each do |key, values|
        constraint = TargetConstraint::Registry.for(key, values)
        return constraint.denial_reason unless constraint.satisfied?(target)
      end
      nil
    end

    def lease_for(credential)
      now = Time.current
      Lease.new(
        id: SecureRandom.uuid,
        credential_id: credential.id,
        credential_name: credential.name,
        credential_type: credential.credential_type,
        issued_at: now,
        expires_at: now + expires_in,
        purpose: purpose,
        tool_name: tool_name
      )
    end

    def yield_with_redaction(credential)
      Redaction.scrub_object(yield, credentials: [ credential ])
    rescue StandardError => e
      raise ExecutionError, Redaction.scrub(e.message, credentials: [ credential ])
    end

    def metadata_for(credential, lease)
      lease.metadata.merge(safe_metadata: credential.safe_metadata, target_constraints: credential.target_constraints)
    end

    def record_event!(credential, result:, denial_reason: nil)
      CredentialAccessEvent.record!(
        credential: credential,
        user: context.user,
        repository: context.repository,
        job: context.job,
        workflow: context.workflow,
        run: context.run,
        chat_session: context.chat_session,
        surface: event_surface,
        tool_name: tool_name,
        action: "lease",
        purpose: purpose,
        result: result,
        denial_reason: denial_reason
      )
    end

    def event_surface
      context.run? ? "workflow" : context.surface.to_s
    end
  end
end
