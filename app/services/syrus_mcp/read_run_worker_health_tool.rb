require "mcp"

module SyrusMcp
  class ReadRunWorkerHealthTool < MCP::Tool
    tool_name "read_run_worker_health"

    description <<~DESC
      Read worker host health samples correlated to a Run's execution window.
      Defaults to the current Run. Insight agents may pass another run_id from
      the same repository to compare host pressure across Runs.
    DESC

    input_schema(
      properties: {
        run_id: {
          type: "integer",
          description: "Optional Run id. Defaults to the current MCP sidecar Run."
        },
        sample_limit: {
          type: "integer",
          description: "Maximum raw correlated samples to return, up to 100. Defaults to 20."
        }
      }
    )

    class << self
      def call(server_context:, run_id: nil, sample_limit: WorkerHealthRunCorrelation::SAMPLE_LIMIT)
        context_run = SyrusMcp.run_from_context(server_context)
        target_run = run_id.present? ? Run.includes(:job, :step, :spawned_processes).find(run_id) : context_run
        unless visible_to_context?(target_run, context_run)
          return SyrusMcp.invalid("run_id is outside this repository scope")
        end

        payload = WorkerHealthRunCorrelation.for_run(target_run, sample_limit: sample_limit)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadRunWorkerHealthTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def visible_to_context?(target_run, context_run)
        return true if target_run.id == context_run.id
        return false unless target_run.job.user_id == context_run.job.user_id

        target_run.job.repository_id == context_run.job.repository_id
      end
    end
  end
end
