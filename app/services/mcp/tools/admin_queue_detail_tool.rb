require "mcp"

module Mcp::Tools
  class AdminQueueDetailTool < MCP::Tool
    TABS = %w[active pending failed recurring workers].freeze

    tool_name "admin_queue_detail"

    description "Read one admin Solid Queue tab: active, pending, failed, recurring, or workers."

    input_schema(
      properties: {
        tab: { type: "string", description: "Queue tab to read: active, pending, failed, recurring, or workers." }
      },
      required: %w[tab]
    )

    class << self
      def call(tab:, server_context:)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        tab = tab.to_s
        return Mcp::Tools.invalid("tab must be one of #{TABS.join(', ')}") unless TABS.include?(tab)

        user = server_context.fetch(:chat_session).user
        payload = ::Admin::Queue::Payload.new(params: { tab: tab }, user: user).public_send(tab)
        Mcp::Tools.success(tab: tab, **payload)
      rescue ActiveRecord::StatementInvalid,
             ActiveRecord::ConnectionNotEstablished,
             ActiveRecord::ActiveRecordError => e
        Mcp::Tools.invalid("SolidQueue tables unreachable from this connection: #{e.message}")
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end
    end
  end
end
