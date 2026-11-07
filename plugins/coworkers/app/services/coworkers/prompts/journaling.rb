module Coworkers
  module Prompts
    class Journaling < ScheduledTasks::SystemSchedules::Definition
      SUPERSEDED_FORMAT = "~~original text~~ (superseded YYYY-MM-DD by <reference>: <reason>)".freeze

      def catch_up_due?(task:, now:)
        first_target = Coworkers::SystemSchedules.target_dates(task, now: now).first
        return false unless first_target

        latest_tick = latest_scheduled_tick(task, now: now)
        return false unless latest_tick

        zone = ActiveSupport::TimeZone[task.schedule_timezone] || ActiveSupport::TimeZone["UTC"]
        first_target <= latest_tick.in_time_zone(zone).to_date - 1
      end

      def failure_date(task:, now:)
        Coworkers::SystemSchedules.target_dates(task, now: now).first
      end

      private

      def latest_scheduled_tick(task, now:)
        cursor = now - 2.days
        latest = nil
        loop do
          candidate = ScheduledTasks::Schedules::RecurringSchedule.next_fire_at(
            task.schedule_expression, timezone: task.schedule_timezone, from: cursor
          )
          break if candidate.nil? || candidate > now

          latest = candidate
          cursor = candidate
        end
        latest
      end

      public

      def prompt(task:, target_date:)
        coworker = Coworkers::Coworker.find(task.coworker_id)
        material = Coworkers::JournalingActivity.new(coworker:, date: target_date).material
        <<~PROMPT
          You are performing your private nightly journaling for #{target_date.iso8601}. Work only on that date.
          This run is silent on success. Do not message your owner and do not create or trigger schedules.

          Organize durable facts from memory/daily/#{target_date.iso8601}.md and the material below into memory/people/, memory/repos/,
          and memory/banks/. Merge duplicates and resolve contradictions while keeping files concise. Never delete memory content.
          Mark entries that are no longer current exactly as:
          `#{SUPERSEDED_FORMAT}`
          Preserve the original text, date, replacement reference, and reason. Tidy only coworker-owned workspace paths; move or mark
          mis-filed notes instead of deleting them. Change SOUL.md, USER.md, or AGENTS.md only when your workspace grant policy permits it.

          Write or update memory/diary/#{target_date.iso8601}.md idempotently. In your own first-person voice, chronicle experiences,
          decisions and their reasons, important discussions, lessons, and open commitments. Link relevant chats and Jobs using canonical
          CHAT-<id> and JOB-<id> references. Do not include secrets or long transcript excerpts.

          ## Material for #{target_date.iso8601}

          #{material}
        PROMPT
      end
    end
  end
end
