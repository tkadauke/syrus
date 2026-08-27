require "mcp"

module Mcp::Tools
  # Changes an existing Job's `delivery_track` before it lands — distinct
  # from the creation-time `delivery_track` selection already exposed on
  # direct-Job/admin-Job creation and `SkillJobs::Creator` (see
  # config/syrus_docs/delivery_tracks.md's "Job#delivery_track" section).
  # Track names are not validated against the repository's configured
  # tracks here either, matching those creation-time surfaces — an
  # unrecognized/unconfigured name just resolves to the `default` track at
  # read time (`DeliveryPolicy#track_for`).
  class SelectJobDeliveryTrackTool < MCP::Tool
    extend RefMovementToolSupport

    tool_name "select_job_delivery_track"

    description "Change a Job's intended delivery track before it is approved or starts landing. " \
                "Only valid while the Job is still open and not yet approved/landing/closed."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        track: { type: "string", description: "Delivery track name (a key under delivery.tracks in .syrus.yml). Blank clears it back to the default track." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:, track: nil)
        context = McpToolContext.from_server_context(server_context)
        job, error = find_context_job(context, job_id)
        return error if error
        return Mcp::Tools.invalid("job is not open") unless job.open?
        return Mcp::Tools.invalid("job has already been approved, is landing, or is closed") if job.approved? || job.landing? || job.closed?

        previous_track = job.delivery_track
        job.update!(delivery_track: track.to_s.strip.presence)

        Mcp::Tools.success(
          job_id: job.id,
          previous_delivery_track: previous_track,
          delivery_track: job.reload.delivery_track,
          resolved_delivery_track: DeliveryPolicy.for(repository: job.repository, job: job).job_delivery_track
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
