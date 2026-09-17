module WorkEngine
  module Simulation
    class ScenarioRunner
      def self.call(path:, max_ticks: nil)
        SolidQueueBootstrap.ensure! if Rails.env.test?
        world = ScenarioLoader.load!(path)
        tick_limit = max_ticks.presence || world.max_ticks.presence || DEFAULT_MAX_TICKS
        success_states = world.success_states.each_with_object({}) do |(key, states), result|
          job = world.jobs_by_key.fetch(key.to_s)
          result[job.slug] = states
          result[job.id.to_s] = states
        end
        wait_states = world.wait_states.each_with_object({}) do |(key, states), result|
          job = world.jobs_by_key.fetch(key.to_s)
          result[job.slug] = states
          result[job.id.to_s] = states
        end
        outcomes = translate_outcomes(world)
        runner_args = {
          scenario: world.name,
          job_ids: world.jobs_by_key.values.map(&:id),
          work_intent_ids: world.work_intents_by_key.values.map(&:id),
          outcomes: outcomes,
          scenario_events: translate_events(world),
          expectations: translate_expectations(world),
          runtime: world.runtime,
          success_states: success_states,
          wait_states: wait_states,
          auto_retry_failed_jobs: world.runner.fetch("auto_retry_failed_jobs", true),
          global_reconcile: world.runner.fetch("global_reconcile", false),
          max_ticks: tick_limit
        }
        if world.reconciler.key?("ignored_issue_kinds")
          runner_args[:ignored_reconciler_issue_kinds] = world.reconciler.fetch("ignored_issue_kinds")
        end
        Runner.call(**runner_args)
      end

      def self.translate_outcomes(world)
        raw = world.outcomes.to_h
        steps = raw.fetch("steps", {}).each_with_object({}) do |(key, value), result|
          token = key.to_s
          job_key, step_kind = token.split(":", 2)
          if step_kind.present? && world.jobs_by_key.key?(job_key)
            job = world.jobs_by_key.fetch(job_key)
            result["#{job.id}:#{step_kind}"] = translate_value(value, world)
          else
            result[token] = translate_value(value, world)
          end
        end
        raw.merge("steps" => steps)
      end

      def self.translate_events(world)
        Array(world.events).map { |event| translate_value(event, world) }
      end

      def self.translate_expectations(world)
        translate_value(world.expectations, world)
      end

      def self.translate_value(value, world)
        case value
        when Array
          value.map { |entry| translate_value(entry, world) }
        when Hash
          value.each_with_object({}) do |(key, entry), result|
            result[key] = translate_reference(key.to_s, entry, world)
          end
        else
          value
        end
      end

      def self.translate_reference(key, value, world)
        if key.in?(%w[job approve fail close set_pr_checks landing_front])
          return translate_job_reference(value, world)
        end

        if key.in?(%w[epic complete_epic])
          return translate_epic_reference(value, world)
        end

        if key == "jobs" && value.is_a?(Hash)
          return value.transform_keys { |job_key| world.jobs_by_key.fetch(job_key.to_s).id.to_s }
        end

        if key == "landing_blocked_reasons" && value.is_a?(Hash)
          return value.transform_keys { |job_key| world.jobs_by_key.fetch(job_key.to_s).id.to_s }
        end

        if key == "epics" && value.is_a?(Hash)
          return value.transform_keys { |epic_key| world.epics_by_key.fetch(epic_key.to_s).id.to_s }
        end

        if key == "stack_results" && value.is_a?(Hash)
          return value.transform_keys { |job_key| world.jobs_by_key.fetch(job_key.to_s).id.to_s }
        end

        translate_value(value, world)
      end

      def self.translate_job_reference(value, world)
        case value
        when Hash
          translated = translate_value(value, world)
          if translated.key?("id")
            translated.merge("id" => world.jobs_by_key.fetch(translated.fetch("id").to_s).id)
          elsif translated.key?(:id)
            translated.merge(id: world.jobs_by_key.fetch(translated.fetch(:id).to_s).id)
          else
            translated
          end
        when Array
          value.map { |entry| translate_job_reference(entry, world) }
        else
          world.jobs_by_key.fetch(value.to_s).id
        end
      end

      def self.translate_epic_reference(value, world)
        case value
        when Hash
          translated = translate_value(value, world)
          if translated.key?("id")
            translated.merge("id" => world.epics_by_key.fetch(translated.fetch("id").to_s).id)
          elsif translated.key?(:id)
            translated.merge(id: world.epics_by_key.fetch(translated.fetch(:id).to_s).id)
          else
            translated
          end
        when Array
          value.map { |entry| translate_epic_reference(entry, world) }
        else
          world.epics_by_key.fetch(value.to_s).id
        end
      end
    end
  end
end
