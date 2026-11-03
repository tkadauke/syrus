require "mcp"
require "time"

module SdlcPipeline
  class ShowPipelineTool < MCP::Tool
    tool_name "show_pipeline"
    description "Open a read-only SDLC Pipeline for an authorized repository using the standard Pipeline FilterBar AST and optional historical presentation state."

    input_schema(
      properties: {
        repository_id: { type: "integer", description: "Authorized Syrus repository ID." },
        filter: { type: "object", description: "Standard validated Pipeline FilterBar AST." },
        at: { type: "string", description: "Optional ISO-8601 historical cursor." },
        range_start: { type: "string", description: "Optional ISO-8601 history range start." },
        range_end: { type: "string", description: "Optional ISO-8601 history range end." }
      },
      required: [ "repository_id", "filter" ]
    )

    class << self
      def call(repository_id:, filter:, server_context:, at: nil, range_start: nil, range_end: nil)
        chat_session = server_context.fetch(:chat_session)
        repository = Repository.accessible_to(chat_session.user).active.find(repository_id)
        ast = Filters::Ast.parse(filter)
        Filters::Compiler.call(ast, scope: Job.none, user: chat_session.user, subject: SmartFolders::SUBJECT).load
        validated = Filters::Ast.serialize(ast)
        at, range_start, range_end = [ at, range_start, range_end ].map { |value| validated_time(value) }
        path = pipeline_path(repository.id, validated, at:, range_start:, range_end:)

        AppEvents.broadcast_chat_resource(
          chat_session_id: chat_session.id, type: "updated", resource: "chat", id: chat_session.id,
          payload: { action: "open_tool_presentation", presentation: "sdlc_pipeline", title_i18n_key: "sdlc_pipeline:title", path: path }
        )
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, filter: validated, path: path,
                           at: at, range_start: range_start, range_end: range_end)
      rescue ArgumentError, ActiveRecord::StatementInvalid => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.invalid("Repository is unavailable.")
      end

      private

      def validated_time(value)
        return if value.blank?

        Time.iso8601(value).iso8601
      rescue ArgumentError
        raise ArgumentError, "Historical presentation values must be ISO-8601 timestamps."
      end

      def pipeline_path(repository_id, filter, at:, range_start:, range_end:)
        params = { q: Filters::QueryParam.encode(filter), at: at, range_start: range_start, range_end: range_end }.compact
        "/repositories/#{repository_id}/plugin/sdlc-pipeline?#{params.to_query}"
      end
    end
  end
end
