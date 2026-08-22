# Short-lived signed context envelope for MCP tool dispatch under the
# persistent MCP sidecar daemon (EPIC-250, PersistentMcpDaemon).
#
# Stdio-mode sidecars (Mcp::Sidecar, bin/syrus-mcp-sidecar,
# bin/syrus-chat-sidecar) get a fresh subprocess per run or chat turn, so
# per-invocation identifiers travel as that subprocess's argv/ENV
# (SYRUS_RUN_ID via --run-id, SYRUS_CHAT_SESSION_ID,
# SYRUS_CHAT_SCOPED_EVENT_ID, ...) -- safe because nothing else shares that
# process. The persistent daemon is one process serving many concurrent
# runs/chats, so ENV (and any daemon-wide "current run"/"current chat"
# attribute) is shared, mutable state that would leak between concurrent
# invocations. #issue_for_run / #issue_for_chat mint a signed, expiring
# token carrying exactly the identifiers stdio mode reads from ENV; #resolve
# verifies it per dispatch and reconstructs the same McpToolContext
# (McpToolContext.from_run / .from_chat_session) stdio mode builds, so tool
# availability stays governed by the existing McpToolPolicy either way.
class McpInvocationContext
  MESSAGE_VERIFIER_PURPOSE = :mcp_invocation
  DEFAULT_EXPIRES_IN = 5.minutes
  VERSION = 1

  REQUIRED_KEYS = %w[v surface worker_id iat exp].freeze
  SURFACES = %w[run chat].freeze

  class InvalidContext < StandardError; end
  class Malformed < InvalidContext; end
  class Expired < InvalidContext; end
  class WrongWorker < InvalidContext; end
  class Unauthorized < InvalidContext; end

  Resolved = Struct.new(
    :tool_context, :surface, :tier, :provider,
    :current_message_id, :scoped_event_id, :evaluator_session_id,
    keyword_init: true
  )

  class << self
    def issue_for_run(run, worker_id:, provider: nil, expires_in: DEFAULT_EXPIRES_IN)
      issue(
        surface: "run",
        worker_id: worker_id,
        expires_in: expires_in,
        payload: {
          "run_id" => run.id,
          "job_id" => run.job_id,
          "provider" => provider
        }
      )
    end

    def issue_for_chat(chat_session, worker_id:, current_message: nil, tier: "essential",
                        evaluator: false, scoped_event_id: nil, evaluator_session_id: nil,
                        provider: nil, expires_in: DEFAULT_EXPIRES_IN)
      issue(
        surface: "chat",
        worker_id: worker_id,
        expires_in: expires_in,
        payload: {
          "chat_session_id" => chat_session.id,
          "current_message_id" => current_message&.id,
          "tier" => tier.to_s,
          "evaluator" => evaluator ? true : false,
          "scoped_event_id" => scoped_event_id,
          "evaluator_session_id" => evaluator_session_id,
          "provider" => provider
        }
      )
    end

    # Verifies and reconstructs a Resolved context for `token`, scoped to the
    # daemon instance identified by `worker_id` (PersistentMcpDaemon#identity's
    # worker_id). Raises a specific InvalidContext subclass -- and logs the
    # rejection -- for every way a token can fail to authorize a dispatch:
    # signature/shape (Malformed), past its expiry (Expired), minted for a
    # different worker (WrongWorker), or naming a run/chat that no longer
    # exists or no longer matches the token's claims (Unauthorized).
    def resolve(token, worker_id:)
      payload = decode(token)
      validate_expiry!(payload)
      validate_worker!(payload, worker_id)
      build_resolved(payload)
    rescue InvalidContext => e
      log_rejection(e, worker_id: worker_id)
      raise
    end

    private

    def issue(surface:, worker_id:, expires_in:, payload:)
      now = Time.current
      full_payload = {
        "v" => VERSION,
        "surface" => surface,
        "worker_id" => worker_id,
        "iat" => now.to_i,
        "exp" => (now + expires_in).to_i
      }.merge(payload.compact)

      verifier.generate(full_payload)
    end

    def decode(token)
      raise Malformed, "blank invocation token" if token.blank?

      payload = verifier.verify(token)
      raise Malformed, "invocation token payload is not a Hash" unless payload.is_a?(Hash)
      raise Malformed, "invocation token missing required fields" unless REQUIRED_KEYS.all? { |key| payload.key?(key) }
      raise Malformed, "unknown invocation token surface #{payload['surface'].inspect}" unless SURFACES.include?(payload["surface"])

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Malformed, "invocation token failed signature verification"
    end

    def validate_expiry!(payload)
      raise Expired, "invocation token expired at #{Time.at(payload['exp'].to_i).utc}" if Time.current.to_i > payload["exp"].to_i
    end

    def validate_worker!(payload, worker_id)
      return if payload["worker_id"] == worker_id

      raise WrongWorker, "invocation token issued for worker #{payload['worker_id'].inspect}, dispatched on #{worker_id.inspect}"
    end

    def build_resolved(payload)
      case payload["surface"]
      when "run"  then build_resolved_for_run(payload)
      when "chat" then build_resolved_for_chat(payload)
      end
    end

    def build_resolved_for_run(payload)
      run = Mcp::Tools.with_database_connection do
        Run.includes(:step, job: :repository).find_by(id: payload["run_id"])
      end
      raise Unauthorized, "run #{payload['run_id']} not found" unless run
      raise Unauthorized, "invocation token job_id does not match run #{run.id}'s job" if payload["job_id"] && run.job_id != payload["job_id"]

      Resolved.new(
        tool_context: McpToolContext.from_run(run),
        surface: :run,
        provider: payload["provider"]
      )
    end

    def build_resolved_for_chat(payload)
      chat_session = Mcp::Tools.with_database_connection do
        ChatSession.find_by(id: payload["chat_session_id"])
      end
      raise Unauthorized, "chat session #{payload['chat_session_id']} not found" unless chat_session

      Resolved.new(
        tool_context: McpToolContext.from_chat_session(chat_session, evaluator: payload["evaluator"] == true),
        surface: :chat,
        tier: payload["tier"],
        provider: payload["provider"],
        current_message_id: payload["current_message_id"],
        scoped_event_id: payload["scoped_event_id"],
        evaluator_session_id: payload["evaluator_session_id"]
      )
    end

    def log_rejection(error, worker_id:)
      Rails.logger.warn("[McpInvocationContext] rejected worker_id=#{worker_id.inspect} reason=#{error.class.name.demodulize} #{error.message}")
    end

    def verifier
      Rails.application.message_verifier(MESSAGE_VERIFIER_PURPOSE)
    end
  end
end
