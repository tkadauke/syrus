# frozen_string_literal: true

module ScheduledTasks
  module Cli
    class Show < Syrus::Host::CliCommandHandler
      def call(args:, flags:, user:)
        task = Task.where(user: user).includes(:repository).find(args.fetch(0))
        recent_jobs = Job.visible_to(user, scope: task.jobs).order(created_at: :desc).limit(5)
        lines = [
          "Schedule ##{task.id}: #{task.name}",
          "State: #{task.state}",
          "Repository: #{task.repository.slug}",
          "Cron: #{value_or_dash(task.cron_expression)}",
          "Next run: #{value_or_dash(task.next_fire_at&.utc&.iso8601)}",
          "Pileup policy: #{value_or_dash(task.pr_pileup_policy)}",
          "Auto approve: #{value_or_dash(task.auto_approve_mode)}",
          "",
          "Prompt:",
          *task.prompt.to_s.split("\n", -1).map { |line| "  #{line}" },
          "",
          "Recent jobs:"
        ]
        lines.concat(recent_jobs.any? ? recent_jobs.map { |job| "  ##{job.id} #{job.state}" } : [ "  none" ])
        self.class.text(lines.join("\n"))
      end

      private

      def value_or_dash(value) = value.to_s.strip.presence || "-"
    end
  end
end
