module Coworkers
  module Prompts
    class ScheduledRunFollowup
      def initialize(task:, run:, summary:, duration_seconds:)
        @task = task
        @run = run
        @summary = summary
        @duration_seconds = duration_seconds
      end

      def to_s
        <<~PROMPT.strip
          This is a follow-up to your scheduled run "#{@task.name}".

          Scheduled instructions:
          #{@task.prompt}

          Result: #{@run.state}
          Run ID: #{@run.id}
          Duration: #{duration_label}
          Cost: #{cost_label}
          Summary:
          #{@summary}

          Follow up with your owner in your own voice. Comment on what matters, flag anything that needs a decision, and use your normal chat tools and capability grants when useful, including proposals, coworker messages, and workspace memory updates. This is an unattended system turn, so owner-facing questions follow the queued-message rules rather than acting like a live owner question.

          Do not repeat the whole background-run card. Do not start or fire another scheduled run as part of this follow-up.
        PROMPT
      end

      private

      def duration_label = @duration_seconds ? "#{@duration_seconds} seconds" : "unavailable"
      def cost_label = @run.cost_usd ? "$#{@run.cost_usd}" : "unavailable"
    end
  end
end
