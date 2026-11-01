module Mcp::Tools
  module PermissionToolSupport
    def self.extended(base)
      base.extend(ProposalToolSupport)
      base.extend(PendingActionToolSupport)
    end

    SUBJECT_PROPERTIES = {
      role: { type: "string", description: "Runtime role whose delegation ceiling must permit this authority." },
      subject_selector_type: { type: "string", enum: PermissionRule::SUBJECT_SELECTOR_TYPES },
      subject_selector_id: { type: "string" },
      subject_repository_id: { type: "integer" },
      capability: { type: "string" },
      operation: { type: "string" },
      resource_scope: { type: "object" },
      constraints: { type: "object" },
      rationale: { type: "string", maxLength: 1000 }
    }.freeze

    private

    def permission_action(server_context, action, payload, message)
      chat = server_context.fetch(:chat_session)
      create_pending_action!(server_context, chat, action:, payload: payload.compact.stringify_keys, message:)
    rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordNotFound, ArgumentError => error
      Mcp::Tools.invalid(error.message)
    end

    def management(server_context) = Permissions::Management.new(server_context.fetch(:chat_session).user)

    def serialize_rule(rule)
      rule.attributes.slice(*PermissionRule::AUDITED_ATTRIBUTES).merge("id" => rule.id)
    end

    def serialize_lease(lease)
      lease.attributes.except("lock_version").merge("active" => lease.revoked_at.nil? && (lease.expires_at.nil? || lease.expires_at.future?))
    end
  end
end
