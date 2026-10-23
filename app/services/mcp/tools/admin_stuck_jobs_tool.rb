require "mcp"

module Mcp::Tools
  class AdminStuckJobsTool < MCP::Tool
    DEFAULT_PER = 50
    MAX_PER = 100

    tool_name "admin_stuck_jobs"

    description "Read one bounded page of the admin stuck Jobs list."

    input_schema(
      properties: {
        page: { type: "integer", description: "1-based page number. Defaults to 1." },
        per: { type: "integer", description: "Items per page. Defaults to 50, capped at 100." }
      }
    )

    class << self
      def call(server_context:, page: 1, per: DEFAULT_PER)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        page = Mcp::Pagination.normalize_page(page)
        per = normalize_per(per)
        result = ::Admin::OverviewPayload.new(
          params: { page: page },
          stuck_per_page: per,
          stable_stuck_order: true
        ).stuck_json
        items = enrich_stuck_job_payloads(result.fetch(:items))
        pagination = result.fetch(:pagination)

        Mcp::Tools.success(
          items: items,
          pagination: {
            page: pagination.fetch(:page),
            per: pagination.fetch(:per_page),
            total_items: pagination.fetch(:total),
            total_pages: pagination.fetch(:total_pages),
            has_next_page: pagination[:next_path].present?,
            has_previous_page: pagination[:previous_path].present?
          }
        )
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def normalize_per(value)
        value.to_i.clamp(1, MAX_PER)
      end

      def enrich_stuck_job_payloads(items)
        jobs = Job.where(id: items.filter_map { |item| item.with_indifferent_access[:job_id] }).index_by(&:id)
        workflows = Workflow.where(id: items.filter_map { |item| item.with_indifferent_access[:workflow_id] }).index_by(&:id)
        runs = Run.where(id: items.filter_map { |item| item.with_indifferent_access[:run_id] }).index_by(&:id)

        items.map do |item|
          row = item.with_indifferent_access
          stuck_job_payload(row, jobs: jobs, workflows: workflows, runs: runs)
        end
      end

      def stuck_job_payload(item, jobs:, workflows:, runs:)
        job = jobs[item[:job_id]]
        workflow = workflows[item[:workflow_id]]
        run = runs[item[:run_id]]
        item.symbolize_keys.merge(
          id: job&.id,
          title: job&.issue_title,
          state: job&.state,
          force_fail_path: nil,
          last_heartbeat_at: run&.last_heartbeat_at&.iso8601,
          workflow_state: workflow&.state,
          run_state: run&.state
        )
      end
    end
  end
end
