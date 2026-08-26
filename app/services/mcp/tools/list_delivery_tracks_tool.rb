require "mcp"

module Mcp::Tools
  class ListDeliveryTracksTool < MCP::Tool
    tool_name "list_delivery_tracks"

    description "List this repository's configured delivery tracks (delivery.tracks in .syrus.yml), " \
                "their resolved branches, and their grade phases."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        context = McpToolContext.from_server_context(server_context)
        repository = context.repository
        return Mcp::Tools.invalid("no repository attached") unless repository

        policy = DeliveryPolicy.for(repository: repository)

        tracks = policy.tracks.map do |name, track|
          {
            name: name,
            default: name == SyrusYml::DEFAULT_DELIVERY_TRACK_NAME,
            branch: track.branch,
            review_grade_phase: track.review_grade_phase,
            landing_grade_phase: track.landing_grade_phase,
            ci_failure_grade_phase: track.ci_failure_grade_phase,
            branch_health_grade_phase: track.branch_health_grade_phase,
            after_landing_sync_to: track.after_landing_sync_to
          }
        end

        Mcp::Tools.success(repository: repository.slug, tracks: tracks)
      end
    end
  end
end
