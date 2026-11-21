require "tempfile"

module CredentialStore
  class Broker
    DEFAULT_LEASE_TTL = 2.minutes
    FILE_PREFIX = "syrus-credential-".freeze
    class Error < StandardError; end
    class NotFound < Error; end
    class Ambiguous < Error; end
    class Denied < Error
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("credential access denied: #{reason}")
      end
    end
    class ExecutionError < Error; end
    class InvalidPayload < Error; end

    class << self
      def with_credential_file(context:, credential:, type:, purpose:, tool_name: nil, target: {}, expires_in: DEFAULT_LEASE_TTL, credential_validator: nil, attempt_metadata: {})
        new(context: context, credential_ref: credential, type: type, purpose: purpose, tool_name: tool_name, target: target, expires_in: expires_in, credential_validator: credential_validator, attempt_metadata: attempt_metadata)
          .with_file { |path, metadata| yield path, metadata }
      end

      def with_credential_env(context:, credential:, type:, env_key:, purpose:, tool_name: nil, target: {}, expires_in: DEFAULT_LEASE_TTL, credential_validator: nil, attempt_metadata: {})
        new(context: context, credential_ref: credential, type: type, purpose: purpose, tool_name: tool_name, target: target, expires_in: expires_in, credential_validator: credential_validator, attempt_metadata: attempt_metadata)
          .with_env(env_key: env_key) { |env, metadata| yield env, metadata }
      end

      def with_credential_payload(context:, credential:, type:, purpose:, tool_name:, target: {}, expires_in: DEFAULT_LEASE_TTL, credential_validator: nil, attempt_metadata: {})
        new(context: context, credential_ref: credential, type: type, purpose: purpose, tool_name: tool_name, target: target, expires_in: expires_in, credential_validator: credential_validator, attempt_metadata: attempt_metadata)
          .with_payload { |payload, metadata| yield payload, metadata }
      end

      def redact(value, credentials: [], extra_secrets: [])
        Redaction.scrub_object(value, credentials: credentials, extra_secrets: extra_secrets)
      end

      def resolve_credential!(context:, credential_ref:)
        candidates = Credential.all
        if integer_ref?(credential_ref)
          credential = candidates.find_by(id: credential_ref)
          return credential if credential&.scope_policy&.usable_by?(credential, context)

          raise NotFound, "credential not found"
        end

        candidates = candidates
          .where(name: credential_ref.to_s, revoked_at: nil)
          .where("expires_at IS NULL OR expires_at > ?", Time.current)
          .select { |candidate| candidate.scope_policy.usable_by?(candidate, context) }
        raise NotFound, "credential not found" if candidates.empty?

        grouped = candidates.group_by { |candidate| candidate.scope_policy.resolution_precedence }
        matches = grouped.fetch(grouped.keys.min)
        raise Ambiguous, "credential name is ambiguous in the selected scope" if matches.many?

        matches.first
      end

      def surface_allowed?(credential, surface:)
        allowed = Array(credential.allowed_surfaces).map(&:to_s)
        allowed.empty? || allowed.include?(surface.to_s)
      end

      def refresh_credential!(credential:, plugin_name:, purpose:, user: nil, metadata: {})
        credential_id = credential.respond_to?(:id) ? credential.id : credential
        Credential.transaction do
          locked = Credential.lock.find(credential_id)
          owner = Syrus::PluginRegistry.credential_type_owner(locked.credential_type)
          raise Denied, "credential type is not managed by #{plugin_name}" unless owner == plugin_name.to_s
          raise Denied, "credential revoked" if locked.revoked?

          previous_payload = locked.payload
          replacement = yield previous_payload
          raise ArgumentError, "refreshed credential payload cannot be blank" if replacement.blank?

          locked.update!(payload: replacement, last_rotated_at: Time.current)
          CredentialAccessEvent.record!(
            credential: locked,
            user: user,
            surface: "api",
            tool_name: plugin_name.to_s,
            action: "refresh",
            purpose: purpose.to_s.presence,
            result: "allowed",
            metadata: Redaction.scrub_object(
              metadata.to_h.merge(payload_replaced: true),
              credentials: [ locked ],
              extra_secrets: [ previous_payload, replacement ]
            )
          )
          locked
        end
      end

      private

      def integer_ref?(credential_ref)
        credential_ref.is_a?(Integer) || credential_ref.to_s.match?(/\A\d+\z/)
      end
    end

    def initialize(context:, credential_ref:, type:, purpose:, tool_name:, target:, expires_in:, credential_validator:, attempt_metadata:)
      @context = context
      @credential_ref = credential_ref
      @type = type.to_s
      @purpose = purpose.to_s
      @tool_name = tool_name.to_s.presence
      @target = (target || {}).to_h.symbolize_keys
      @expires_in = expires_in
      @credential_validator = credential_validator
      @attempt_metadata = (attempt_metadata || {}).to_h
    end

    def with_file
      credential = authorized_credential!
      lease = lease_for(credential)
      record_event!(credential, result: "allowed", metadata: lease.metadata)
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
      record_event!(credential, result: "allowed", metadata: lease.metadata)
      env = { env_key.to_s => credential.payload }

      yield_with_redaction(credential) { yield env, metadata_for(credential, lease) }
    ensure
      env&.clear
    end

    def with_payload
      credential = authorized_credential!
      lease = lease_for(credential)
      lease_event = record_event!(credential, result: "allowed", metadata: lease.metadata)

      yield_with_redaction(credential) { yield credential.payload.dup, metadata_for(credential, lease) }
    ensure
      record_release_event!(credential, lease, lease_event) if credential && lease && lease_event
    end

    private

    attr_reader :context, :credential_ref, :type, :purpose, :tool_name, :target, :expires_in, :credential_validator, :attempt_metadata

    def authorized_credential!
      credential = resolve_credential
      unless credential
        record_event!(nil, result: "denied", denial_reason: "credential not found", metadata: { credential_ref: credential_ref.to_s.truncate(120) })
        raise NotFound, "credential not found"
      end

      unless credential.scope_policy.usable_by?(credential, context)
        record_event!(credential, result: "denied", denial_reason: "credential scope not usable")
        raise NotFound, "credential not found"
      end

      denial_reason = denial_reason_for(credential)
      if denial_reason
        record_event!(credential, result: "denied", denial_reason: denial_reason)
        raise Denied, denial_reason
      end

      credential
    rescue Ambiguous
      record_event!(nil, result: "denied", denial_reason: "credential name is ambiguous", metadata: { credential_ref: credential_ref.to_s.truncate(120) })
      raise
    end

    def resolve_credential
      if credential_ref.is_a?(Integer) || credential_ref.to_s.match?(/\A\d+\z/)
        Credential.find_by(id: credential_ref)
      else
        self.class.resolve_credential!(context: context, credential_ref: credential_ref)
      end
    rescue NotFound
      nil
    end

    def denial_reason_for(credential)
      return "credential revoked" if credential.revoked?
      return "credential expired" if credential.expired?
      return "incompatible credential type" unless credential.credential_type == type
      return "surface not allowed" unless surface_allowed?(credential)
      consumer_reason = consumer_denial_reason(credential)
      return consumer_reason if consumer_reason

      custom_reason = custom_denial_reason(credential)
      target_denial_reason(credential) || custom_reason
    end

    def surface_allowed?(credential)
      self.class.surface_allowed?(credential, surface: event_surface)
    end

    def consumer_denial_reason(credential)
      consumer = ConsumerRegistry.find(tool_name)
      return "unavailable typed consumer" if tool_name&.start_with?("credential_store_") && !consumer
      return legacy_tool_denial_reason(credential) unless consumer
      return "incompatible credential type" unless consumer.compatible_with?(credential.credential_type)
      return if consumer.kind == :typed

      return "plugin-managed credential cannot use raw wrappers" if ConsumerRegistry.plugin_managed_type?(credential.credential_type)

      allowed = Array(credential.allowed_tools).map(&:to_s)
      "raw-wrapper opt-in missing" if allowed.exclude?(tool_name)
    end

    def legacy_tool_denial_reason(credential)
      allowed = Array(credential.allowed_tools).map(&:to_s)
      "tool not allowed" unless allowed.empty? || (tool_name.present? && allowed.include?(tool_name))
    end

    def target_denial_reason(credential)
      credential.target_constraints.each do |key, values|
        constraint = TargetConstraint::Registry.for(key, values)
        return constraint.denial_reason unless constraint.satisfied?(target)
      end
      nil
    end

    def custom_denial_reason(credential)
      return unless credential_validator

      credential_validator.call(credential).presence
    rescue StandardError => e
      metadata = e.respond_to?(:audit_metadata) ? e.audit_metadata : {}
      metadata = Redaction.scrub_object(metadata, credentials: [ credential ])
      record_event!(credential, result: "denied", denial_reason: e.message.to_s.truncate(255), metadata: metadata)
      raise
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

    def record_event!(credential, result:, denial_reason: nil, metadata: {})
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
        denial_reason: denial_reason,
        metadata: sanitized_metadata(credential, metadata),
        lease_id: result == "allowed" ? metadata[:lease_id] : nil
      )
    end

    def record_release_event!(credential, lease, lease_event)
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
        action: "revoke",
        purpose: purpose,
        result: "allowed",
        metadata: sanitized_metadata(credential, lease.metadata.merge(released: true)),
        completion_of_event: lease_event
      )
    end

    def sanitized_metadata(credential, metadata)
      Redaction.scrub_object(attempt_metadata.merge(metadata), credentials: Array(credential))
    end

    def event_surface
      context.run? ? "workflow" : context.surface.to_s
    end
  end
end
