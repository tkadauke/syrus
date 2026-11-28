# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "yaml"

module WorkEngine
  module Simulation
    # Turns the scripted scenarios into a bug finder.
    #
    # Production bugs mostly come from event orderings nobody scripted: a
    # worker dying mid-step, main moving mid-landing, an operator pausing
    # work, GitHub flaking. The fuzzer takes existing scenarios as seeds and,
    # with a deterministic RNG, injects perturbation events from a catalog at
    # random ticks inside the seed's own timeline. Every perturbation is an
    # event the runner already knows how to express, so a failing iteration
    # is just another scenario file: the fuzzer shrinks it (drops injected
    # events while the failure persists) and writes the reproduction to
    # tmp/simulator_fuzz/, ready to be promoted to a regression scenario.
    #
    #   bin/simulator --fuzz [--seed N] [--iterations K] [--iteration I] [--no-shrink] [scenario...]
    #
    # An iteration passes when no invariant is violated at any tick and the
    # scenario either reaches the seed's expected status or settles: every
    # Job in a state that names why it stopped (see Oracle).
    module Fuzz
      DEFAULT_OUTPUT_DIR = Rails.root.join("tmp/simulator_fuzz")
      DEFAULT_SEED = 1
      DEFAULT_ITERATIONS = 50

      # Judges one perturbed run. A perturbation legitimately changes how a
      # story ends -- a PR closed externally never reaches the seed's
      # `expect:` -- so a world that stops changing passes when every Job is
      # in a state that names why it stopped: done, failed, or waiting on an
      # operator (implemented, approved and landing, whose progress the
      # landing_progress invariant separately asserts), or held by an operator
      # pause. A Job left queued or running in a quiet world with nobody
      # holding it is the silent stall the fuzzer hunts.
      module Oracle
        SETTLED_JOB_STATES = %w[implemented approved landing closed failed no_change_needed].freeze

        # nil when the run passes, otherwise a short failure signature that
        # stays stable while shrinking.
        def self.failure_signature(result, expected_statuses:)
          if result.violated?
            keys = result.invariant_violations.filter_map { |line| line[/invariant (\w+)/, 1] }.uniq.sort
            return "invariant:#{keys.join(",").presence || "unknown"}"
          end
          return "error:#{result.stuck_reasons.first.to_s[/\A[\w:]+/]}" if result.error?
          return nil if expected_statuses.include?(result.status)
          return nil if result.stuck? && settled?(result)

          "#{result.status}:#{result.stuck_reasons.first}"
        end

        def self.settled?(result)
          result.final_states.present? && result.final_states.values.all? { |state| SETTLED_JOB_STATES.include?(state) || state.end_with?(":manual_paused") }
        end
      end

      # The perturbation catalog. Each entry draws one or two scenario events
      # (string-keyed, fixture job keys) scheduled by tick.
      class Catalog
        TRANSIENT_FAILURE_CODES = %w[provider_transient timeout git_transport_transient rate_limited run_job_crashed].freeze
        STEP_KINDS = [ nil, "prepare", "implement", "grader_fanout", "grader_collect", "grader", "pr_open", "push", "auto_merge", "merge_train_land" ].freeze
        JOBLESS_KINDS = %w[advance_main main_break_heal provider_outage spurious_wake lose_worker].freeze
        Context = Data.define(:job_keys, :stack_children, :workers, :workspace, :ticks, :git)

        def self.context_for(data, ticks:)
          jobs = data.fetch("jobs", {}).to_h
          Context.new(
            job_keys: jobs.keys.map(&:to_s).sort,
            stack_children: jobs.select { |_key, attrs| attrs.to_h["parent_job"].present? }.keys.map(&:to_s).sort,
            workers: Array(data.dig("runtime", "workers")).map(&:to_s),
            workspace: data.dig("runtime", "workspace").present?,
            ticks: [ ticks.to_i, 1 ].max,
            git: data.key?("git")
          )
        end

        def initialize(rng, context)
          @rng = rng
          @context = context
        end

        # An operator force-failing a Job is deliberately absent: a failed Job
        # with waiting dependents is exactly what failed_blockers reports, so
        # the perturbation only ever rediscovers the invariant working.
        def kinds
          @kinds ||= begin
            weighted = {
              "advance_main" => 3, "approve" => 2, "transient_failure" => 3, "worker_died" => 3,
              "grader_killed_by_deploy" => 2, "main_break_heal" => 2, "provider_outage" => 2,
              "ci_flake" => 2, "report_ci_failure" => 1, "close_externally" => 1, "merge_externally" => 1,
              "set_job_provider" => 1, "resume_deferred_phase" => 2, "spurious_wake" => 1, "pause_unpause" => 3
            }
            weighted["rewrite_stack_parent"] = 3 if context.stack_children.any?
            weighted["lose_worker"] = 2 if context.workers.any?
            weighted["lose_storage"] = 1 if context.workspace
            # Seeds that model git topology can also have a PR's base gain
            # an overlapping change, or a branch rewritten under the engine.
            if context.git
              weighted["pr_becomes_dirty"] = 2
              weighted["rewrite_branch"] = 2
            end
            # A seed made only of WorkIntents has no Job to aim at.
            weighted.select! { |kind, _| JOBLESS_KINDS.include?(kind) } if context.job_keys.empty?
            weighted.sort.flat_map { |kind, weight| [ kind ] * weight }
          end
        end

        def draw(count)
          count.times.flat_map do |index|
            kind = kinds.sample(random: rng)
            build(kind, index)
          end
        end

        private

        attr_reader :rng, :context

        def tick = rng.rand(context.ticks)
        def later(from) = from + 1 + rng.rand(10)
        def job = context.job_keys.sample(random: rng)

        def build(kind, index)
          at = tick
          case kind
          when "advance_main" then [ event(kind, index, at, "advance_main" => { "nonce" => "fuzz-#{index}-#{at}" }) ]
          when "approve" then [ event(kind, index, at, "approve" => job) ]
          when "transient_failure"
            code = TRANSIENT_FAILURE_CODES.sample(random: rng)
            outcome = { "status" => "failure", "failure_code" => code, "error_message" => "simulated transient #{code}" }
            [ event(kind, index, at, "inject_outcome" => { "job" => job, "outcome" => outcome }) ]
          when "worker_died"
            [ event(kind, index, at, "inject_outcome" => { "job" => job, "step" => STEP_KINDS.sample(random: rng), "outcome" => "worker_died" }.compact) ]
          when "grader_killed_by_deploy"
            step = %w[grader_fanout grader_collect grader].sample(random: rng)
            [ event(kind, index, at, "inject_outcome" => { "job" => job, "step" => step, "outcome" => "worker_died" }) ]
          when "main_break_heal"
            [ event("break_main", index, at, "break_main_branch" => true),
              event("heal_main", index, later(at), "heal_main_branch" => true) ]
          when "provider_outage"
            heal = later(at)
            [ event("exhaust_provider", index, at, "exhaust_provider_usage" => "codex"),
              event("refresh_provider", index, heal, "refresh_provider_usage" => "codex", "wake_provider_admission" => "codex") ]
          when "ci_flake"
            key = job
            [ event("ci_failing", index, at, { "set_pr_checks" => { "job" => key, "state" => "failing" } }, key),
              event("ci_passing", index, later(at), { "set_pr_checks" => { "job" => key, "state" => "passing" } }, key) ]
          when "report_ci_failure"
            key = job
            [ event(kind, index, at, { "report_ci_failure" => { "job" => key } }, key) ]
          when "close_externally"
            key = job
            [ event(kind, index, at, { "merge_pr" => { "job" => key, "merged" => false } }, key) ]
          when "merge_externally"
            key = job
            [ event(kind, index, at, { "merge_pr" => { "job" => key, "merged" => true } }, key) ]
          when "set_job_provider" then [ event(kind, index, at, "set_job_provider" => { "job" => job, "provider" => "claude" }) ]
          when "resume_deferred_phase" then [ event(kind, index, at, "resume_deferred_phase" => { "job" => job }) ]
          when "spurious_wake" then [ event(kind, index, at, "wake" => "all") ]
          when "pause_unpause"
            key = job
            [ event("pause", index, at, "pause_work" => key), event("unpause", index, later(at), "unpause_work" => key) ]
          when "rewrite_stack_parent" then [ event(kind, index, at, "rewrite_stack_parent" => context.stack_children.sample(random: rng)) ]
          when "lose_worker" then [ event(kind, index, at, "lose_worker" => { "hostname" => context.workers.sample(random: rng) }) ]
          when "lose_storage" then [ event(kind, index, at, "lose_storage" => { "job" => job }) ]
          when "pr_becomes_dirty"
            key = job
            [ event(kind, index, at, { "pr_becomes_dirty" => key }, key) ]
          when "rewrite_branch"
            key = job
            [ event(kind, index, at, { "rewrite_branch" => { "job" => key, "patch_equivalent" => rng.rand(2).zero? } }, key) ]
          else raise ArgumentError, "unknown fuzz perturbation #{kind}"
          end
        end

        def event(kind, index, at, actions, has_pr = nil)
          condition = { "tick" => { "at_least" => at } }
          condition = { "all" => [ condition, { "job" => { "id" => has_pr, "has_pr" => true } } ] } if has_pr
          { "name" => "fuzz #{index + 1}: #{kind}", "once" => true, "fuzz" => kind, "when" => condition, "do" => actions }
        end
      end

      Iteration = Data.define(:index, :seed, :path, :events, :result, :signature)
      Failure = Data.define(:iteration, :minimized_events, :repro_path, :reproduced)

      class Fuzzer
        def self.call(...) = new(...).call

        def initialize(paths:, seed: DEFAULT_SEED, iterations: DEFAULT_ITERATIONS, only_iteration: nil, shrink: true,
                       max_events: 4, output_dir: DEFAULT_OUTPUT_DIR, out: $stdout, runner: nil)
          @paths = Array(paths).map { |path| Pathname(path) }.sort_by(&:to_s)
          @seed = Integer(seed)
          @iterations = Integer(iterations)
          @only_iteration = only_iteration&.then { |value| Integer(value) }
          @shrink = shrink
          @max_events = max_events
          @output_dir = Pathname(output_dir)
          @out = out
          @runner = runner || method(:run_scenario_file)
          @baselines = {}
        end

        # Returns [iterations, failures].
        def call
          eligible = paths.select { |path| eligible_seed?(path) }
          raise ArgumentError, "no seed scenario passed its unperturbed baseline" if eligible.empty?

          indexes = only_iteration ? [ only_iteration ] : (0...iterations).to_a
          ran = []
          failures = []
          indexes.each do |index|
            iteration = run_iteration(index, eligible)
            ran << iteration
            report_iteration(iteration)
            failures << record_failure(iteration) if iteration.signature
          end
          out.puts "fuzz: #{ran.size} iterations (seed #{seed}), #{failures.size} failures"
          [ ran, failures ]
        end

        # The perturbed scenario of one iteration, without running it.
        def plan(index, eligible)
          rng = Random.new(iteration_seed(index))
          path = eligible[rng.rand(eligible.size)]
          data = load(path)
          catalog = Catalog.new(rng, Catalog.context_for(data, ticks: baseline(path).ticks))
          [ path, data, catalog.draw(1 + rng.rand(max_events)) ]
        end

        def shrink_events(path, data, events, signature)
          current = events
          loop do
            reduced = current.each_index.lazy.map { |index| current.dup.tap { |copy| copy.delete_at(index) } }.find do |candidate|
              failure_signature(path, run(data, candidate)) == signature
            end
            break unless reduced

            current = reduced
          end
          current
        end

        private

        attr_reader :paths, :seed, :iterations, :only_iteration, :max_events, :output_dir, :out, :runner

        def iteration_seed(index)
          Digest::SHA256.hexdigest("syrus-simulator-fuzz:#{seed}:#{index}").first(16).to_i(16)
        end

        def eligible_seed?(path)
          result = baseline(path)
          return true if expected_statuses(path).include?(result.status) && !result.violated?

          out.puts "fuzz: skipping seed #{relative(path)}: baseline ended #{result.status} (expected #{expected_statuses(path).join("|")})"
          false
        end

        def baseline(path)
          @baselines[path.to_s] ||= run(load(path), [])
        end

        def run_iteration(index, eligible)
          path, data, events = plan(index, eligible)
          result = run(data, events)
          Iteration.new(index: index, seed: seed, path: path, events: events, result: result, signature: failure_signature(path, result))
        end

        def record_failure(iteration)
          minimized = @shrink ? shrink_events(iteration.path, load(iteration.path), iteration.events, iteration.signature) : iteration.events
          repro = write_repro(iteration, minimized)
          reproduced = failure_signature(iteration.path, runner.call(repro)) == iteration.signature
          out.puts "  minimized to #{minimized.size} injected events -> #{relative(repro)}#{reproduced ? "" : " (WARNING: the written file did not reproduce)"}"
          minimized.each { |event| out.puts "    #{describe(event)}" }
          Failure.new(iteration: iteration, minimized_events: minimized, repro_path: repro, reproduced: reproduced)
        end

        def report_iteration(iteration)
          result = iteration.result
          verdict = iteration.signature ? "FAIL #{iteration.signature}" : "pass"
          out.puts "iteration #{iteration.index} (seed #{seed}) #{relative(iteration.path)}: #{verdict} -- #{result.status} after #{result.ticks} ticks#{settled_note(result)}"
          return unless iteration.signature

          out.puts "  replay: bin/simulator --fuzz --seed #{seed} --iteration #{iteration.index} #{relative(iteration.path)}"
          iteration.events.each { |event| out.puts "    #{describe(event)}" }
          result.stuck_reasons.first(8).each { |reason| out.puts "  #{reason}" }
        end

        # A pass that only settled (rather than reaching the seed's expected
        # status) says where every Job stopped, so a reviewer can tell an
        # explicable end from a suspicious one.
        def settled_note(result)
          return "" if result.success? || result.waiting? || result.final_states.blank?

          " (" + result.final_states.map { |slug, state| "#{slug}=#{state}" }.join(" ") + ")"
        end

        def describe(event)
          tick = event.dig("when", "tick", "at_least") || event.dig("when", "all", 0, "tick", "at_least")
          "tick >= #{tick}: #{event["name"]} #{event["do"].to_json}"
        end

        def write_repro(iteration, events)
          FileUtils.mkdir_p(output_dir)
          base = iteration.path.basename(".*").to_s
          target = output_dir.join("#{base}__seed#{seed}_iter#{iteration.index}.yml")
          data = perturbed(load(iteration.path), events).merge(
            "fuzz" => {
              "base" => relative(iteration.path),
              "seed" => seed,
              "iteration" => iteration.index,
              "signature" => iteration.signature
            }
          )
          target.write(data.to_yaml)
          target
        end

        def failure_signature(path, result)
          Oracle.failure_signature(result, expected_statuses: expected_statuses(path))
        end

        def expected_statuses(path)
          status = load(path)["expected_status"].presence
          status ? Array(status).map(&:to_s) : %w[success waiting]
        end

        def load(path)
          @loaded ||= {}
          @loaded[path.to_s] ||= YAML.safe_load(Pathname(path).read, permitted_classes: [ Symbol ], aliases: false).to_h.freeze
          @loaded[path.to_s].deep_dup
        end

        def perturbed(data, events)
          data.merge("events" => Array(data["events"]) + events)
        end

        def run(data, events)
          FileUtils.mkdir_p(output_dir.join("work"))
          file = output_dir.join("work/current.yml")
          file.write(perturbed(data, events).to_yaml)
          runner.call(file)
        end

        def run_scenario_file(file)
          ScenarioExecution.call(path: file)
        rescue => e
          Result.new(
            scenario: file.basename.to_s, ticks: 0, status: "error", events: [],
            stuck_reasons: [ "#{e.class}: #{e.message}", *Array(e.backtrace).first(5) ],
            wait_reasons: [], job_ids: [], epic_ids: [], work_intent_ids: []
          )
        end

        def relative(path)
          Pathname(path).expand_path.relative_path_from(Rails.root).to_s
        rescue ArgumentError
          path.to_s
        end
      end
    end
  end
end
