module Coworkers
  # Builds one bounded snapshot on the shared metrics tick. Scrapes only read
  # this cache, so coworker joins and aggregates never run in the web request.
  class MetricsSampler
    CACHE_KEY = "coworkers:metrics:snapshot".freeze
    CACHE_TTL = 5.minutes
    STATES = %w[scheduled paused auto_paused].freeze
    RESULTS = %w[journaled skipped failed].freeze

    def self.sample! = new.sample!
    def self.refresh_gauges! = new.refresh_gauges!

    def sample!(now: Time.current)
      coworkers = Coworkers::Coworker.where.not(state: "archived").pluck(:id, :handle)
      ids = coworkers.map(&:first)
      snapshot = { "observed_at" => now.iso8601(6), "coworkers" => {} }
      schedules = ScheduledTasks::Task.alive.where(coworker_id: ids, system_key: Coworkers::SystemSchedules::JOURNALING).index_by(&:coworker_id)
      unsaved = Coworkers::Chat.where(coworker_id: ids).where.not(unsaved_workspace_first_failed_at: nil)
        .group(:coworker_id).pluck(:coworker_id, Arel.sql("MIN(unsaved_workspace_first_failed_at)"), Arel.sql("SUM(unsaved_workspace_attempt_count)"))
        .to_h { |id, oldest, attempts| [ id, [ oldest, attempts ] ] }
      chat_spend = Syrus::Host::ChatSpendEntry.joins("INNER JOIN coworker_chats ON coworker_chats.chat_session_id = chat_spend_entries.chat_session_id")
        .where(coworker_chats: { coworker_id: ids }).group("coworker_chats.coworker_id").sum(:cost_usd)
      run_spend = Syrus::Host::RunRecord.joins(:job).where(jobs: { kind: "coworker_task", origin: "coworkers", origin_id: ids.map(&:to_s) })
        .group("jobs.origin_id").sum(:cost_usd)
      seven_days_ago = now - 7.days
      weekly_chat_spend = Syrus::Host::ChatSpendEntry.joins("INNER JOIN coworker_chats ON coworker_chats.chat_session_id = chat_spend_entries.chat_session_id")
        .where(coworker_chats: { coworker_id: ids }, incurred_at: seven_days_ago..now).group("coworker_chats.coworker_id").sum(:cost_usd)
      weekly_run_spend = Syrus::Host::RunRecord.joins(:job).where(jobs: { kind: "coworker_task", origin: "coworkers", origin_id: ids.map(&:to_s) }, finished_at: seven_days_ago..now)
        .group("jobs.origin_id").sum(:cost_usd)

      coworkers.each do |id, handle|
        task = schedules[id]
        oldest, attempts = unsaved.fetch(id, [ nil, 0 ])
        snapshot["coworkers"][handle] = {
          "journaling_state" => task&.state,
          "journaling_result" => task&.last_system_result,
          "journaling_age" => result_age(task, now),
          "journaling_failures" => task&.consecutive_failure_count.to_i,
          "unsaved_age" => oldest ? [ now - time_value(oldest), 0 ].max : 0,
          "unsaved_attempts" => attempts.to_i,
          "chat_spend" => chat_spend.fetch(id, 0).to_f,
          "background_run_spend" => run_spend.fetch(id.to_s, 0).to_f,
          "weekly_spend" => weekly_chat_spend.fetch(id, 0).to_f + weekly_run_spend.fetch(id.to_s, 0).to_f
        }
      end
      Rails.cache.write(CACHE_KEY, snapshot, expires_in: CACHE_TTL)
      true
    rescue StandardError => error
      Rails.logger.warn("[Coworkers::MetricsSampler] could not sample coworker health: #{error.class}: #{error.message}")
      false
    end

    def refresh_gauges!
      snapshot = Rails.cache.read(CACHE_KEY)
      return false unless snapshot

      clear_published_series!(snapshot.fetch("coworkers").keys)

      snapshot.fetch("coworkers").each do |handle, values|
        tags = { coworker: handle }
        set(:journaling_last_result_age_seconds, values["journaling_age"], tags) if values["journaling_age"]
        set(:journaling_consecutive_failures, values["journaling_failures"], tags)
        set(:unsaved_workspace_age_seconds, values["unsaved_age"], tags)
        set(:unsaved_workspace_attempts, values["unsaved_attempts"], tags)
        STATES.each { |state| set(:journaling_state, state == values["journaling_state"] ? 1 : 0, tags.merge(state: state)) }
        RESULTS.each { |result| set(:journaling_last_result, result == values["journaling_result"] ? 1 : 0, tags.merge(result: result)) }
        counter(:spend_usd_total).reconcile!(values["chat_spend"], tags: tags.merge(source: "chat"))
        counter(:spend_usd_total).reconcile!(values["background_run_spend"], tags: tags.merge(source: "background_run"))
      end
      true
    end

    private

    def result_age(task, now)
      return unless task

      date = Array(task.system_result_history).filter_map do |entry|
        Date.iso8601(entry["date"]) if entry["result"].in?(%w[journaled skipped]) && entry["date"].present?
      rescue Date::Error
        nil
      end.max
      date ||= task.last_system_result_on if task.last_system_result.in?(%w[journaled skipped])
      return unless date
      zone = ActiveSupport::TimeZone[task.schedule_timezone] || ActiveSupport::TimeZone["UTC"]
      [ now - zone.local(date.year, date.month, date.day), 0 ].max
    end

    def time_value(value)
      value.respond_to?(:in_time_zone) && !value.is_a?(String) ? value.in_time_zone : Time.zone.parse(value.to_s)
    end

    def set(name, value, tags) = Syrus::Host::Metrics.gauge(:"syrus_coworkers_#{name}").set(value, tags: tags)
    def counter(name) = Syrus::Host::Metrics.counter(:"syrus_coworkers_#{name}")

    def clear_published_series!(active_handles)
      %i[journaling_last_result_age_seconds journaling_consecutive_failures unsaved_workspace_age_seconds unsaved_workspace_attempts journaling_state journaling_last_result].each do |name|
        Syrus::Host::Metrics.gauge(:"syrus_coworkers_#{name}").samples.each { |tags, _| Syrus::Host::Metrics.gauge(:"syrus_coworkers_#{name}").clear(tags:) }
      end
      %i[spend_usd_total workspace_push_failures_total].each do |name|
        counter(name).samples.each do |tags, _|
          counter(name).clear(tags:) unless active_handles.include?(tags[:coworker])
        end
      end
    end
  end
end
