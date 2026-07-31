require "mcp"

module Mcp::Tools
  class GetSpendingTool < MCP::Tool
    tool_name "get_spending"

    description "Read spending insights for the current chat user."

    input_schema(
      properties: {
        window: { type: "string", enum: %w[7d 30d 90d], description: "Date window. Defaults to 30d." },
        repository_id: { type: "integer", description: "Optional repository id filter." },
        epic_id: { type: "integer", description: "Optional epic id filter." }
      }
    )

    WINDOW_DAYS = {
      "7d" => 7,
      "30d" => 30,
      "90d" => 90
    }.freeze

    class << self
      def call(server_context:, window: "30d", repository_id: nil, epic_id: nil)
        chat_session = server_context.fetch(:chat_session)
        window = window.to_s.presence || "30d"
        return Mcp::Tools.invalid("window must be one of 7d, 30d, 90d") unless WINDOW_DAYS.key?(window)

        params = payload_params(window: window, repository_id: repository_id, epic_id: epic_id)
        payload = App::SpendingPayload.new(user: chat_session.user, params: params).as_json

        Mcp::Tools.success(
          total_cost_usd: total_cost(payload),
          total_input_tokens: windowed_runs(chat_session.user, params).sum(:input_tokens),
          total_output_tokens: windowed_runs(chat_session.user, params).sum(:output_tokens),
          top_runs: payload.fetch(:top_runs).first(5).map { |run| top_run_payload(run) },
          by_day: payload.fetch(:trend).map { |point| { date: point.fetch(:date), cost_usd: point.fetch(:total_usd) } }
        )
      end

      private

      def payload_params(window:, repository_id:, epic_id:)
        days = WINDOW_DAYS.fetch(window)
        end_date = Time.zone.today
        {
          start_date: (end_date - (days - 1).days).iso8601,
          end_date: end_date.iso8601,
          repository_id: repository_id,
          epic_id: epic_id
        }.compact
      end

      def windowed_runs(user, params)
        start_date = Date.iso8601(params.fetch(:start_date))
        end_date = Date.iso8601(params.fetch(:end_date))
        relation = Run.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
        relation = relation.joins(:job).where(jobs: { repository_id: params[:repository_id] }) if params[:repository_id].present?
        relation = relation.joins(:job).where(jobs: { epic_id: params[:epic_id] }) if params[:epic_id].present?
        return relation if user.admin?

        relation.where(user_id: user.id)
      end

      def total_cost(payload)
        payload.fetch(:trend).sum { |point| point.fetch(:total_usd).to_d }.to_f
      end

      def top_run_payload(run)
        {
          job_id: run.dig(:job, :id),
          title: run.dig(:job, :title),
          cost_usd: run.fetch(:cost_usd)
        }
      end
    end
  end
end
