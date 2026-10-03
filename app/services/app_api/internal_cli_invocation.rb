module AppApi
  class InternalCliInvocation
    HEADER = "X-Syrus-CLI-Command".freeze
    DENIED_MESSAGE =
      "Internal Syrus CLI invocation contexts allow read-only app API commands. " \
      "Use the MCP/admin confirmation path for mutating operations.".freeze

    attr_reader :controller, :context

    def initialize(controller, context:)
      @controller = controller
      @context = context
    end

    def self.active?(session)
      session.respond_to?(:invocation_context) && session.invocation_context.present?
    end

    def read_only?
      request.get? || request.head?
    end

    def allowed?
      read_only? || credential_lease_request?
    end

    def audit(status:)
      OperationalLogging.ingest(
        level: status.to_i >= 400 ? "warn" : "info",
        source: "internal_cli",
        message: "internal CLI #{command_namespace} #{outcome_for(status)}",
        context: audit_context(status)
      )
    end

    def command_namespace
      value = request.headers[HEADER].presence || "#{request.request_method.downcase} #{request.path}"
      CommandRedactor.redact(value).safe_byteslice(0, 200)
    end

    private

    def request
      controller.request
    end

    def audit_context(status)
      {
        method: request.request_method,
        path: request.path,
        controller: controller.controller_path,
        action: controller.action_name,
        status: status.to_i,
        outcome: outcome_for(status),
        command_namespace: command_namespace,
        user_id: context.user&.id,
        repository_id: context.repository&.id,
        repository_slug: context.repository&.slug,
        chat_session_id: context.chat_session&.id,
        surface: context.surface,
        role: context.role,
        job_id: context.job&.id,
        workflow_id: context.workflow&.id,
        run_id: context.run&.id
      }.compact
    end

    def outcome_for(status)
      status = status.to_i
      return "denied" if status == 403 && !allowed?
      return "error" if status >= 500
      return "rejected" if status >= 400

      "allowed"
    end

    def credential_lease_request?
      request.post? && request.path == "/api/v1/app/credential_store/leases"
    end
  end
end
