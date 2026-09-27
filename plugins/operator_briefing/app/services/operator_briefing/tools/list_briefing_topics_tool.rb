require "mcp"

module OperatorBriefing
  module Tools
    class ListBriefingTopicsTool < MCP::Tool
      tool_name "list_briefing_topics"

      description "Lists existing Operator Briefing wiki topics for the current repository so a dive can avoid creating near-duplicates."

      input_schema(
        properties: {
          query: { type: "string", description: "Optional text to roughly filter topic titles." }
        }
      )

      class << self
        def call(server_context:, query: nil)
          run = Mcp::Tools.run_from_context(server_context)
          topics = BriefingTopic.where(repository: run.job.repository).order(updated_at: :desc, id: :desc)
          topics = topics.where("title LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s)}%") if query.present?

          Mcp::Tools.success(
            topics: topics.limit(25).map { |topic| topic_payload(topic) }
          )
        end

        private

        def topic_payload(topic)
          latest = topic.latest_revision
          {
            id: topic.id,
            slug: topic.slug,
            title: topic.title,
            latest_revision_number: latest&.revision_number,
            latest_summary: latest&.narrative.to_s.truncate(500),
            path: "/briefing/topics/#{topic.id}"
          }
        end
      end
    end
  end
end
