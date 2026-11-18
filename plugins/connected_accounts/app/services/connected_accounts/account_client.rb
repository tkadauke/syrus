module ConnectedAccounts
  class AccountClient
    TOOL_NAME = "connected_accounts.account_client".freeze
    CREDENTIAL_TYPE = "connected_accounts.oauth".freeze
    PURPOSE_MAX_LENGTH = 120

    class Error < StandardError; end
    class Denied < Error; end
    class InvalidCredential < Error; end

    class << self
      attr_accessor :token_refresher

      def with_access(account:, acting_mode:, scopes:, purpose:, context:, target: {})
        new(account:, acting_mode:, scopes:, purpose:, context:, target:).with_access { |access| yield access }
      end
    end

    def initialize(account:, acting_mode:, scopes:, purpose:, context:, target:)
      @account_ref = account
      @acting_mode = acting_mode.to_s
      @scopes = Array(scopes).filter_map { |scope| scope.to_s.strip.presence }.uniq.sort
      @purpose = purpose.to_s.squish
      @context = context
      @target = target.to_h
    end

    def with_access
      account = resolve_account!
      authorize_invocation!(account)
      credential = account.credential
      redact_purpose!(credential)

      CredentialStore::Broker.with_credential(
        context:, credential: credential.id, type: CREDENTIAL_TYPE, purpose:,
        tool_name: TOOL_NAME, target:, credential_validator: ->(_) { validation_denial(account) },
        attempt_metadata: audit_metadata(account)
      ) do |payload, lease_metadata|
        tokens = {}
        result = nil
        failed = true
        begin
          tokens = parse_payload(payload)
          tokens = refresh_tokens_if_needed(account, credential, tokens)
          result = yield Access.new(tokens.fetch("access_token"))
          failed = false
        rescue StandardError => e
          message = CredentialStore::Broker.redact(
            e.message, credentials: [ credential ],
            extra_secrets: [ tokens["access_token"], tokens["refresh_token"] ]
          )
          raise CredentialStore::Broker::ExecutionError, message
        ensure
          record_completion!(credential, lease_metadata, account, result: failed ? "failed" : "allowed")
        end
        CredentialStore::Broker.redact(
          result, credentials: [ credential ],
          extra_secrets: [ tokens["access_token"], tokens["refresh_token"] ]
        )
      end
    rescue CredentialStore::Broker::Error => e
      raise Denied, e.message
    end

    private

    attr_reader :account_ref, :acting_mode, :scopes, :purpose, :context, :target

    def resolve_account!
      account = account_ref.is_a?(Account) ? account_ref : Account.find_by(id: account_ref)
      raise Denied, "connected account not found" unless account
      raise Denied, "connected account belongs to another user" unless account.owner_user_id == context.user&.id

      account
    end

    def authorize_invocation!(account)
      authorization = context.permission_authorization
      raise Denied, "authorized invocation reference is required" if authorization.blank?
      if authorization["tool_name"].blank? || authorization["invocation_fingerprint"].blank?
        raise Denied, "authorized invocation reference is incomplete"
      end
    end

    def validation_denial(account)
      return "connected account is not connected" unless account.reload.connected?
      return "acting mode is not eligible for this account" unless account.permits_acting_mode?(acting_mode)
      "requested scopes exceed the account grant or ceiling" unless account.permits_scopes?(scopes)
    end

    def parse_payload(payload)
      parsed = JSON.parse(payload)
      raise InvalidCredential, "OAuth credential has no access token" if parsed["access_token"].blank?

      parsed
    rescue JSON::ParserError
      raise InvalidCredential, "OAuth credential payload is invalid"
    end

    def refresh_tokens_if_needed(account, credential, tokens)
      expires_at = Time.zone.parse(tokens["expires_at"].to_s) if tokens["expires_at"].present?
      return tokens unless expires_at && expires_at <= Time.current
      raise InvalidCredential, "OAuth credential needs refresh" unless self.class.token_refresher

      refreshed = CredentialStore::Broker.refresh_credential!(
        credential:, plugin_name: "connected_accounts", purpose:,
        user: context.user, metadata: audit_metadata(account)
      ) { |current| JSON.generate(self.class.token_refresher.call(account:, payload: JSON.parse(current))) }
      parse_payload(refreshed.payload)
    end

    def redact_purpose!(credential)
      tokens = parse_payload(credential.payload)
      @purpose = CredentialStore::Broker.redact(
        purpose, credentials: [ credential ],
        extra_secrets: [ tokens["access_token"], tokens["refresh_token"] ]
      ).truncate(PURPOSE_MAX_LENGTH)
    end

    def audit_metadata(account)
      {
        provider: account.provider_key, connected_account_id: account.id,
        acting_mode:, scopes:, purpose:
      }
    end

    def record_completion!(credential, lease_metadata, account, result:)
      lease_event = CredentialStore::CredentialAccessEvent.find_by!(lease_id: lease_metadata.fetch(:lease_id))
      CredentialStore::CredentialAccessEvent.record!(
        credential:, user: context.user, repository: context.repository, job: context.job,
        workflow: context.workflow, run: context.run, chat_session: context.chat_session,
        surface: context.run? ? "workflow" : context.surface.to_s, tool_name: TOOL_NAME,
        action: "use", purpose:, result:,
        metadata: audit_metadata(account).merge(lease_id: lease_metadata.fetch(:lease_id)),
        completion_of_event: lease_event
      )
    end
  end
end
