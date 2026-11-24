require "mcp"

module Coworkers::McpTools
  class ReadCoworkerTool < MCP::Tool
    tool_name "read_coworker"
    description "Read operational configuration for exactly one coworker owned by the signed-in user, identified by numeric coworker_id or handle."
    input_schema(
      properties: {
        coworker_id: { type: "integer", description: "Owner-scoped numeric coworker ID." },
        handle: { type: "string", description: "Owner-scoped coworker handle, with or without @." }
      },
      oneOf: [ { required: [ "coworker_id" ] }, { required: [ "handle" ] } ]
    )

    class << self
      def call(server_context:, coworker_id: nil, handle: nil)
        owner = server_context.fetch(:chat_session).user
        coworker = Coworkers::OwnerResolver.new(owner: owner).find!(id: coworker_id, handle: handle)
        coworker.coworker_chats.includes(:chat_session).load
        Syrus::Host::McpTools.success(coworker: Coworkers::McpPresenter.new(coworker).detail)
      rescue ActiveRecord::RecordNotFound
        Syrus::Host::McpTools.invalid("coworker not found")
      rescue ArgumentError => error
        Syrus::Host::McpTools.invalid(error.message)
      end
    end
  end
end
