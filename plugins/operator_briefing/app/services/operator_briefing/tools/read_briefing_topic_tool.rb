require "mcp"

module OperatorBriefing
  module Tools
    class ReadBriefingTopicTool < MCP::Tool
      tool_name "read_briefing_topic"

      description "Reads one existing Operator Briefing wiki topic and its latest revision."

      input_schema(
        properties: {
          topic_id: { type: "integer", description: "Existing topic id from list_briefing_topics." }
        },
        required: %w[topic_id]
      )

      class << self
        def call(topic_id:, server_context:)
          run = Mcp::Tools.run_from_context(server_context)
          topic = BriefingTopic.where(repository: run.job.repository).find(topic_id)
          revision = topic.latest_revision

          Mcp::Tools.success(
            topic: {
              id: topic.id,
              slug: topic.slug,
              title: topic.title,
              path: "/briefing/topics/#{topic.id}",
              latest_revision: revision && {
                id: revision.id,
                revision_number: revision.revision_number,
                generated_at: revision.generated_at&.iso8601,
                narrative: revision.narrative,
                findings: revision.findings,
                references: revision.references
              }
            }
          )
        rescue ActiveRecord::RecordNotFound
          Mcp::Tools.invalid("briefing topic not found")
        end
      end
    end
  end
end
