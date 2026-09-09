module WorkEngine
  module Simulation
    class ScenarioRunner
      def self.call(path:, max_ticks: DEFAULT_MAX_TICKS)
        world = ScenarioLoader.load!(path)
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
          success_states: success_states,
          wait_states: wait_states,
          max_ticks: max_ticks
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
          if token.include?(":")
            job_key, step_kind = token.split(":", 2)
            job = world.jobs_by_key.fetch(job_key)
            result["#{job.id}:#{step_kind}"] = value
          else
            result[token] = value
          end
        end
        raw.merge("steps" => steps)
      end
    end
  end
end
