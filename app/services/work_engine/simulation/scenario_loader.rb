require "yaml"
require "set"
require "digest/sha1"

module WorkEngine
  module Simulation
    class ScenarioLoader
      World = Data.define(:name, :repository, :user, :jobs_by_key, :epics_by_key, :work_intents_by_key, :outcomes, :events, :expectations, :success_states, :wait_states, :reconciler, :runner)
      REPOSITORY_UPDATE_KEYS = %w[
        auto_merge_enabled main_branch_health_enabled main_branch_repair_enabled
        main_branch_repair_blocks_work landing_paused
      ].freeze
      JOB_UPDATE_KEYS = %w[
        state closure_reason pr_number branch_name pr_checks_state pr_checks_sha
        commits_behind_base manual_paused approved_at approved_via landed_sha
        external_pr_number external_pr_author external_pr_fork mergeability_base_sha
        mergeability_head_sha github_mergeable github_mergeable_state
      ].freeze

      def self.load!(path) = new(path).load!

      def initialize(path)
        @path = Pathname(path)
      end

      def load!
        raise ArgumentError, "simulation scenario not found: #{path}" unless path.file?

        data = YAML.safe_load(path.read, permitted_classes: [ Symbol ], aliases: false).to_h
        validate_acyclic_dependencies!(data)

        ActiveRecord::Base.transaction(requires_new: true) do
          user = create_user!(data.fetch("user", {}))
          configure_app_settings!(data.fetch("app_settings", {}))
          repository = create_repository!(user, data.fetch("repository", {}))
          epics = create_epics!(user, repository, data.fetch("epics", {}))
          jobs = create_jobs!(user, repository, epics, data.fetch("jobs", {}))
          create_stack_parent_links!(jobs, data.fetch("jobs", {}))
          create_epic_dependencies!(epics, data.fetch("epics", {}))
          create_job_dependencies!(jobs, epics, data.fetch("jobs", {}))
          create_workflows!(jobs, data.fetch("jobs", {}))
          create_merge_trains!(repository, epics, jobs, data.fetch("merge_trains", {}))
          work_intents = create_standalone_work!(repository, user, jobs, data.fetch("work_intents", {}), data.fetch("work_units", {}))

          World.new(
            name: data.fetch("name", path.basename(".yml").to_s),
            repository: repository,
            user: user,
            jobs_by_key: jobs,
            epics_by_key: epics,
            work_intents_by_key: work_intents,
            outcomes: data.fetch("outcomes", {}),
            events: data.fetch("events", []),
            expectations: data.fetch("expect", {}),
            success_states: data.fetch("success_states", {}),
            wait_states: data.fetch("wait_states", {}),
            reconciler: data.fetch("reconciler", {}),
            runner: data.fetch("runner", {})
          )
        end
      end

      private

      attr_reader :path

      def create_user!(attrs)
        User.create!(
          email_address: attrs.fetch("email", "simulation-#{SecureRandom.hex(6)}@example.com"),
          password: attrs.fetch("password", "supersecret"),
          agent_provider: attrs.fetch("agent_provider", "codex")
        )
      end

      def configure_app_settings!(attrs)
        attrs = attrs.to_h
        return if attrs.blank?

        AppSetting.current.update!(attrs.slice(*AppSetting.column_names))
      end

      def create_repository!(user, attrs)
        repository = Repository.create!(
          user: user,
          owner: attrs.fetch("owner", "simulation"),
          name: attrs.fetch("name", "repo-#{SecureRandom.hex(4)}"),
          default_branch: attrs.fetch("default_branch", "main")
        )
        updates = attrs.slice(*REPOSITORY_UPDATE_KEYS)
        repository.update!(updates) if updates.present?
        repository
      end

      def create_epics!(user, repository, definitions)
        definitions.each_with_object({}) do |(key, attrs), result|
          result[key.to_s] = Epic.create!(
            user: user,
            repository: repository,
            title: attrs.fetch("title", key.to_s.humanize),
            state: attrs.fetch("state", "in_progress")
          )
        end
      end

      def create_jobs!(user, repository, epics, definitions)
        issue_number = 10_000
        definitions.each_with_object({}) do |(key, attrs), result|
          epic = epics[attrs["epic"].to_s] if attrs["epic"].present?
          job = Job.create!(
            user: user,
            owner_user: user,
            repository: repository,
            epic: epic,
            kind: attrs.fetch("kind", "issue"),
            issue_number: attrs["issue_number"] || (issue_number += 1),
            issue_title: attrs.fetch("title", key.to_s.humanize),
            issue_body: attrs.fetch("body", "Synthetic work-engine simulation job #{key}."),
            state: "closed",
            agent_provider: attrs.fetch("agent_provider", user.agent_provider)
          )
          job.update_columns(job_updates(attrs))
          result[key.to_s] = job.reload
        end
      end

      def job_updates(attrs)
        updates = { "state" => attrs.fetch("state", "queued") }
        JOB_UPDATE_KEYS.each do |key|
          updates[key] = attrs[key] if attrs.key?(key)
        end
        updates["approved_at"] = Time.zone.parse(updates["approved_at"]) if updates["approved_at"].present?
        updates
      end

      def create_epic_dependencies!(epics, definitions)
        definitions.each do |key, attrs|
          epic = epics.fetch(key.to_s)
          Array(attrs["depends_on"]).each do |dependency_key|
            EpicDependency.create!(
              epic: epic,
              depends_on_epic: epics.fetch(dependency_key.to_s),
              derived: false
            )
          end
        end
      end

      def create_job_dependencies!(jobs, epics, definitions)
        definitions.each do |key, attrs|
          job = jobs.fetch(key.to_s)
          Array(attrs["depends_on"]).each do |dependency|
            case dependency.to_s
            when /\Ajob:(.+)\z/
              JobDependency.create!(job: job, depends_on_job: jobs.fetch(Regexp.last_match(1)), source: "manual")
            when /\Aepic:(.+)\z/
              JobDependency.create!(job: job, depends_on_epic: epics.fetch(Regexp.last_match(1)), source: "manual")
            else
              JobDependency.create!(job: job, depends_on_job: jobs.fetch(dependency.to_s), source: "manual")
            end
          end
        end
      end

      def create_stack_parent_links!(jobs, definitions)
        definitions.each do |key, attrs|
          parent_key = attrs["parent_job"]
          next if parent_key.blank?

          jobs.fetch(key.to_s).update!(parent_job: jobs.fetch(parent_key.to_s))
        end
      end

      def create_workflows!(jobs, definitions)
        definitions.each do |key, attrs|
          workflow_config = attrs["workflow"]
          next unless workflow_config

          job = jobs.fetch(key.to_s)
          workflow = if workflow_config["template"] == true
            WorkUnits::Launcher.instantiate(kind: workflow_config.fetch("kind", "initial"), job: job)
          else
            create_manual_workflow!(job, workflow_config)
          end

          workflow.update_columns(state: workflow_config.fetch("state", workflow.state))
          sync_work_unit_state!(workflow, workflow_config)
        end
      end

      def create_merge_trains!(repository, epics, jobs, definitions)
        definitions.each do |key, attrs|
          epic = epics[attrs["epic"].to_s] if attrs["epic"].present?
          train = MergeTrain.create!(
            epic: epic,
            repository: repository,
            priority: attrs["priority"],
            base_branch: attrs.fetch("base_branch", repository.default_branch),
            integration_branch: attrs.fetch("integration_branch", "syrus/simulated-merge-train-#{key}"),
            state: attrs.fetch("state", "succeeded"),
            failure_reason: attrs["failure_reason"],
            integration_sha: attrs["integration_sha"] || simulated_sha("merge-train", key)
          )
          train.update_columns(
            created_at: parse_optional_time(attrs["created_at"]) || 5.minutes.ago,
            finished_at: parse_optional_time(attrs["finished_at"]) || 1.minute.ago
          )
          create_merge_train_members!(train, jobs, attrs.fetch("members", []))
          create_landed_commits!(epics, jobs, train, attrs.fetch("landed_commits", {}))
        end
      end

      def create_merge_train_members!(train, jobs, definitions)
        definitions.each_with_index do |entry, index|
          attrs = entry.is_a?(Hash) ? entry : { "job" => entry }
          MergeTrainMember.create!(
            merge_train: train,
            job: jobs.fetch(attrs.fetch("job").to_s),
            position: attrs.fetch("position", index),
            state: attrs.fetch("state", "failed"),
            reason: attrs["reason"]
          )
        end
      end

      def create_landed_commits!(epics, jobs, train, definitions)
        Array(definitions["epic"]).each_with_index do |attrs, index|
          LandedCommit.create!(
            landable: train.epic || epics.fetch(attrs.fetch("epic").to_s),
            sha: attrs["sha"] || simulated_sha("epic-landed", "#{train.id}-#{index}"),
            kind: attrs.fetch("kind", "integration_merge"),
            position: attrs.fetch("position", index),
            created_at: parse_optional_time(attrs["created_at"]) || train.finished_at
          )
        end
        definitions.fetch("jobs", {}).each do |job_key, commits|
          Array(commits).each_with_index do |attrs, index|
            LandedCommit.create!(
              landable: jobs.fetch(job_key.to_s),
              sha: attrs["sha"] || simulated_sha("job-landed", "#{job_key}-#{train.id}-#{index}"),
              kind: attrs.fetch("kind", "implementation"),
              position: attrs.fetch("position", index),
              created_at: parse_optional_time(attrs["created_at"]) || train.created_at + 1.second
            )
          end
        end
      end

      def create_manual_workflow!(job, config)
        workflow = Workflow.new(
          job: job,
          user: job.user,
          trigger_kind: config.fetch("kind", "initial"),
          agent_provider: config.fetch("agent_provider", job.agent_provider),
          priority: job.priority,
          state: "queued",
          chain_template: Array(config["steps"]).map { |step| { "type" => "step", "kind" => step.fetch("kind") } },
          artifacts: config.fetch("artifacts", {})
        )
        workflow.save!(validate: false)
        workflow.update_columns(created_at: parse_optional_time(config["created_at"])) if config["created_at"].present?
        steps = Array(config.fetch("steps")).each_with_index.map do |step_config, index|
          Step.create!(
            workflow: workflow,
            kind: step_config.fetch("kind"),
            position: step_config.fetch("position", index),
            state: step_config.fetch("state", "queued")
          ).tap do |step|
            step.update_columns(created_at: parse_optional_time(step_config["created_at"])) if step_config["created_at"].present?
            create_run!(job, workflow, step, step_config["run"]) if step_config["run"]
          end
        end
        steps.each_cons(2) do |step, next_step|
          step.update!(next_step: next_step)
          next_step.update!(depends_on_ids: [ step.id ])
        end
        attach_work_unit!(job, workflow, config)
        workflow
      end

      def create_run!(job, workflow, step, config)
        Run.create!(
          job: job,
          step: step,
          trigger_kind: workflow.trigger_kind,
          agent_provider: config.fetch("agent_provider", workflow.agent_provider),
          state: "skipped",
          agent_outcome: config["agent_outcome"],
          started_at: config["started_at"] ? Time.zone.parse(config.fetch("started_at")) : nil,
          finished_at: config["finished_at"] ? Time.zone.parse(config.fetch("finished_at")) : nil
        ).tap do |run|
          updates = { state: config.fetch("state", "queued") }
          updates[:head_sha] = config["head_sha"] if config["head_sha"].present?
          updates[:base_sha] = config["base_sha"] if config["base_sha"].present?
          run.update_columns(updates)
          diagnostic = config["diagnostic"]
          if diagnostic
            RunDiagnostic.create!(
              run: run,
              error_class: diagnostic["error_class"],
              error_message: diagnostic["error_message"]
            )
          end
          Array(config["spawned_processes"]).each do |process|
            SpawnedProcess.create!(
              run: run,
              workflow: workflow,
              kind: process.fetch("kind", "agent"),
              command: process.fetch("command", "#{process.fetch("kind", "agent")} command"),
              hostname: process.fetch("hostname", "simulation-worker"),
              pid: process["pid"],
              pgid: process["pgid"],
              started_at: parse_optional_time(process["started_at"]) || run.started_at || Time.current,
              last_chunk_at: parse_optional_time(process["last_chunk_at"]),
              finished_at: parse_optional_time(process["finished_at"]),
              outcome: process["outcome"]
            )
          end
        end
      end

      def attach_work_unit!(job, workflow, config)
        intent = WorkIntent.create!(
          kind: workflow.trigger_kind,
          state: config.dig("intent", "state") || "requested",
          repository: job.repository,
          scope_type: config.dig("scope", "type") || "job",
          scope_id: config.dig("scope", "id") || job.id,
          actor: job.user,
          source_type: "work_engine_simulation"
        )
        unit = WorkUnit.create!(
          work_intent: intent,
          workflow: workflow,
          kind: workflow.trigger_kind,
          state: config.dig("work_unit", "state") || workflow.state,
          blocked_reason: config.dig("work_unit", "blocked_reason"),
          blocked_details: config.dig("work_unit", "blocked_details") || {},
          blocked_until: parse_optional_time(config.dig("work_unit", "blocked_until")),
          repository: job.repository,
          scope_type: intent.scope_type,
          scope_id: intent.scope_id
        )
        unit.work_unit_members.create!(job: job, role: "primary")
        unit.work_unit_locks.create!(lock_key: "job:#{job.id}") if unit.active?
      end

      def sync_work_unit_state!(workflow, config)
        unit = workflow.work_unit
        return unless unit

        unit.update_columns(state: config.dig("work_unit", "state") || workflow.state)
      end

      def create_standalone_work!(repository, user, jobs, intent_definitions, unit_definitions)
        intents = create_standalone_intents!(repository, user, jobs, intent_definitions)
        create_standalone_units!(repository, jobs, intents, unit_definitions)
        intents
      end

      def create_standalone_intents!(repository, user, jobs, definitions)
        definitions.each_with_object({}) do |(key, attrs), result|
          scope_type, scope_id = scope_for(attrs, jobs)
          result[key.to_s] = WorkIntent.create!(
            kind: attrs.fetch("kind", "initial"),
            state: attrs.fetch("state", "requested"),
            repository: repository,
            scope_type: scope_type,
            scope_id: scope_id,
            actor: user,
            source_type: "work_engine_simulation",
            wait_reason: attrs["wait_reason"],
            wait_until: parse_optional_time(attrs["wait_until"]),
            wait_details: attrs.fetch("wait_details", {})
          ).tap do |intent|
            intent.update_columns(created_at: parse_optional_time(attrs["created_at"])) if attrs["created_at"].present?
          end
        end
      end

      def create_standalone_units!(repository, jobs, intents, definitions)
        definitions.each do |key, attrs|
          intent = intents.fetch(attrs.fetch("intent").to_s)
          scope_type, scope_id = scope_for(attrs, jobs)
          unit = WorkUnit.create!(
            work_intent: intent,
            kind: attrs.fetch("kind", intent.kind),
            state: attrs.fetch("state", "queued"),
            repository: repository,
            scope_type: scope_type,
            scope_id: scope_id,
            blocked_reason: attrs["blocked_reason"],
            blocked_details: attrs.fetch("blocked_details", {}),
            blocked_until: parse_optional_time(attrs["blocked_until"]),
            preemption_reason: attrs["preemption_reason"]
          )
          unit.update_columns(created_at: parse_optional_time(attrs["created_at"])) if attrs["created_at"].present?
          Array(attrs["members"]).each do |member|
            unit.work_unit_members.create!(job: jobs.fetch(member.to_s), role: "primary")
          end
          Array(attrs["locks"]).each do |lock|
            unit.work_unit_locks.create!(lock_key: lock_for(lock, jobs))
          end
        end
      end

      def scope_for(attrs, jobs)
        if attrs["job"].present?
          [ "job", jobs.fetch(attrs.fetch("job").to_s).id ]
        else
          [ attrs.fetch("scope_type", "repository"), attrs.fetch("scope_id", nil) ]
        end
      end

      def lock_for(value, jobs)
        token = value.to_s
        if (match = token.match(/\Ajob:(.+)\z/))
          return "job:#{jobs.fetch(match[1]).id}"
        end

        token
      end

      def validate_acyclic_dependencies!(data)
        validate_graph!("epic", data.fetch("epics", {}).transform_values { |attrs| Array(attrs["depends_on"]) })
        validate_graph!("job", data.fetch("jobs", {}).transform_values { |attrs| Array(attrs["depends_on"]).grep_v(/\Aepic:/) })
      end

      def parse_optional_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      end

      def simulated_sha(prefix, key)
        Digest::SHA1.hexdigest("#{path}:#{prefix}:#{key}")
      end

      def validate_graph!(label, graph)
        visiting = Set.new
        visited = Set.new
        visit = lambda do |key|
          key = key.to_s.delete_prefix("job:")
          raise ArgumentError, "cyclic #{label} dependency at #{key}" if visiting.include?(key)
          return if visited.include?(key)

          visiting << key
          Array(graph[key]).each { |child| visit.call(child.to_s.delete_prefix("job:")) if graph.key?(child.to_s.delete_prefix("job:")) }
          visiting.delete(key)
          visited << key
        end
        graph.keys.each { |key| visit.call(key) }
      end
    end
  end
end
