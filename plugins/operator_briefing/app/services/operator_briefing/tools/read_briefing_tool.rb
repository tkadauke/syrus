require "mcp"

module OperatorBriefing
  module Tools
    class ReadBriefingTool < MCP::Tool
      tool_name "read_briefing"

      description "Reads the full current Operator Briefing for this run's anchor Job, including latest content blocks and briefing items."

      input_schema(
        properties: {}
      )

      class << self
        def call(server_context:)
          run = Mcp::Tools.run_from_context(server_context)
          briefing = Briefing
            .includes(:repository, :job, :items, :revisions)
            .find_by!(job: run.job)
          revision = briefing.latest_revision

          Mcp::Tools.success(
            briefing: {
              id: briefing.id,
              slug: briefing.slug,
              path: "/briefing",
              repository: {
                id: briefing.repository_id,
                slug: briefing.repository.slug
              },
              job: {
                id: briefing.job_id,
                slug: briefing.job.slug,
                path: "/jobs/#{briefing.job_id}"
              },
              window_start: briefing.window_start&.iso8601,
              window_end: briefing.window_end&.iso8601,
              latest_revision: revision && {
                id: revision.id,
                revision_number: revision.revision_number,
                generated_at: revision.generated_at&.iso8601,
                content_blocks: revision.content_blocks
              },
              items: briefing.items.order(:id).map { |item| item_payload(item) }
            }
          )
        rescue ActiveRecord::RecordNotFound
          Mcp::Tools.invalid("briefing not found for this run")
        end

        private

        def item_payload(item)
          {
            id: item.id,
            severity: item.severity,
            narrative: item.narrative,
            evidence: item.evidence
          }
        end
      end
    end
  end
end
