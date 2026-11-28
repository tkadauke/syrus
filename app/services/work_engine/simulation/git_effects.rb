# frozen_string_literal: true

module WorkEngine
  module Simulation
    # Connects a scenario's GitWorld to the simulator's boundaries. Only
    # scenarios that declare a `git:` block get one; every other scenario keeps
    # the simulator's older answers (a PR is always cleanly mergeable, git is
    # faked away).
    #
    # The boundaries, and what runs for real behind each:
    #
    #   GithubClient.for            -> GitWorld::GithubClient. PollMergeStateJob
    #                                  runs for real against it: mergeability
    #                                  recording, AutoMergeGate, every rebase
    #                                  dispatch guard, RebaseWorkflowSelector.
    #   RepositoryContent providers -> branch resolution and ahead/behind
    #                                  counts (the poller's live base, its
    #                                  commits-behind distance).
    #   step execution              -> the step kinds below move branches in the
    #                                  model. pr_open runs the real
    #                                  StackBaseFreshness barrier over a
    #                                  GitWorld::SimulatedGit checkout; the
    #                                  rebase steps rebase onto the base branch
    #                                  the real RebaseTarget / StackRebasePlan
    #                                  chose, and fail the way a fetch of a
    #                                  missing ref fails.
    class GitEffects
      COMMIT_STEP_KINDS = %w[implement respond analyze_and_fix landing_fix run_skill].freeze
      PUSH_STEP_KINDS = %w[push force_push push_after_rebase push_agent_rebase stack_force_push].freeze
      MERGE_STEP_KINDS = %w[auto_merge].freeze
      MERGE_TRAIN_STEP_KINDS = %w[merge_train_land merge_train_land_after_rebase].freeze
      # Kinds whose older simulator side effect (closing the landed Jobs)
      # still runs after the git world merged their PRs.
      CHAINED_STEP_KINDS = (MERGE_STEP_KINDS + MERGE_TRAIN_STEP_KINDS).freeze
      HANDLED_STEP_KINDS = (
        COMMIT_STEP_KINDS + PUSH_STEP_KINDS + MERGE_STEP_KINDS + MERGE_TRAIN_STEP_KINDS +
          %w[pr_open auto_rebase agent_rebase stack_auto_rebase stack_agent_rebase]
      ).freeze

      Failure = Data.define(:failure_code, :error_message, :problem_code)

      attr_reader :world, :events

      def initialize(world:, job_ids:, events:)
        @world = world
        @job_ids = job_ids
        @events = events
        @pending_pushes = Hash.new { |hash, key| hash[key] = {} }
        @poll_fingerprints = {}
        @polled_job_ids = Set.new
      end

      def handles?(step_kind) = HANDLED_STEP_KINDS.include?(step_kind.to_s)

      # ---- boundaries ------------------------------------------------------

      def install
        world_ref = world
        log = ->(message) { events << message unless events.last == message }
        original_for = ::GithubClient.method(:for)
        ::GithubClient.define_singleton_method(:for) { |repository:, user: nil| GitWorld::GithubClient.new(world_ref, repository: repository, log: log) }

        previous_providers = RepositoryContent.provider_classes_override
        RepositoryContent.provider_classes_override = [ content_provider_class, *RepositoryContent.provider_classes ]
        yield
      ensure
        ::GithubClient.define_singleton_method(:for, original_for) if original_for
        RepositoryContent.provider_classes_override = previous_providers if defined?(previous_providers)
      end

      # ---- merge-state polling --------------------------------------------

      # Runs the real PollMergeStateJob for every scenario Job whose PR the
      # landing queue asked about, and -- standing in for
      # PollAllMergeStatesJob's periodic fan-out -- for every open Job with a
      # PR whenever the git world or the Job's own state changed since its
      # last poll. A poll that would observe exactly what the previous one did
      # is skipped: it would decide the same thing again.
      def poll_merge_states!(tick, requested_ids:, state_fingerprint:)
        candidates = Job.where(id: @job_ids).where.not(pr_number: nil).where.not(state: "closed").order(:id).pluck(:id)
        (candidates | requested_ids).sort.each do |job_id|
          fingerprint = [ world.fingerprint, state_fingerprint ]
          next if @poll_fingerprints[job_id] == fingerprint

          @poll_fingerprints[job_id] = fingerprint
          job = Job.find(job_id)
          pr = world.pull_request(job.pr_number)
          next unless pr

          before = job.github_mergeable_state
          first_poll = @polled_job_ids.add?(job_id)
          PollMergeStateJob.new.perform(job_id)
          after = job.reload.github_mergeable_state
          next unless first_poll || before != after

          events << "tick #{tick}: merge-state poll for #{job.slug} PR ##{pr.number} -> #{after || "not recorded"}#{" (was #{before})" if before.present? && before != after}"
        end
      end

      # ---- step effects ----------------------------------------------------

      # nil on success, a Failure when the step must fail the way the real
      # one would have.
      def apply(run, outcome)
        kind = run.step&.kind.to_s
        case kind
        when *COMMIT_STEP_KINDS then commit_work!(run)
        when "pr_open" then open_or_update_pull_request!(run)
        when *PUSH_STEP_KINDS then push_pending!(run)
        when "auto_rebase" then auto_rebase!(run)
        when "agent_rebase" then agent_rebase!(run)
        when "stack_auto_rebase" then stack_auto_rebase!(run)
        when "stack_agent_rebase" then stack_agent_rebase!(run)
        when *MERGE_STEP_KINDS then merge_job!(run)
        when *MERGE_TRAIN_STEP_KINDS then merge_train!(run, outcome)
        end
      end

      # ---- events ----------------------------------------------------------

      def advance_main!(attrs)
        branch = attrs["branch"].presence || world.default_branch
        world.advance_branch!(branch, label: attrs["label"], patch: attrs["patch"], paths: attrs["paths"].presence || [ "#{branch}-#{attrs["nonce"] || "advance"}-#{world.unique_token}.txt" ])
      end

      def advance_branch!(value)
        attrs = value.to_h
        branch = branch_from(attrs)
        world.advance_branch!(branch, label: attrs["label"], patch: attrs["patch"], paths: attrs["paths"])
        events << "#{branch} advanced to #{short(world.resolve(branch))}"
      end

      def pr_becomes_dirty!(value)
        job = job_from(value)
        pr = pull_request_for!(job)
        world.make_pull_request_dirty!(pr.number)
        events << "#{pr.base_branch} gained a change overlapping #{job.slug} PR ##{pr.number}"
      end

      def pr_mergeability_unknown!(value)
        attrs = value.is_a?(Hash) ? value : { "job" => value }
        pr = pull_request_for!(Job.find(attrs.fetch("job")))
        pr.unknown_reads = attrs.fetch("reads", 1).to_i
        events << "GitHub is recomputing mergeability of PR ##{pr.number}"
      end

      def rewrite_branch!(value)
        attrs = value.to_h
        branch = branch_from(attrs)
        unless world.branch?(branch)
          events << "rewrite #{branch} skipped: branch does not exist"
          return
        end

        before = world.resolve(branch)
        after = world.rewrite_branch!(branch, onto: attrs["onto"].presence, patch_equivalent: attrs.fetch("patch_equivalent", true))
        world.pushed!(branch)
        events << "rewrote #{branch} #{short(before)} -> #{short(after)}#{" with edited patches" unless attrs.fetch("patch_equivalent", true)}"
      end

      def force_push_branch!(value)
        attrs = value.to_h
        branch = branch_from(attrs)
        world.set_branch!(branch, attrs.fetch("to"))
        world.pushed!(branch)
        events << "force-pushed #{branch} to #{short(world.resolve(branch))}"
      end

      def delete_branch!(value)
        branch = branch_from(value.is_a?(Hash) ? value : { "branch" => value })
        world.delete_branch!(branch)
        events << "deleted branch #{branch}"
      end

      # A stack parent rebased and force-pushed (patch-equivalent) while its
      # child works; the child's pr_open meets the real StackBaseFreshness.
      def rewrite_stack_parent!(child)
        parent = child.parent_job
        return events << "rewrite stack parent of #{child.slug} skipped: no parent" unless parent&.branch_name.present? && world.branch?(parent.branch_name)

        base = world.pull_request_for_branch(parent.branch_name)&.base_branch || world.default_branch
        world.advance_branch!(base, paths: [ "#{base}-under-#{parent.id}-#{world.unique_token}.txt" ])
        rewrite_branch!("branch" => parent.branch_name, "onto" => base)
        parent.update_columns(mergeability_head_sha: world.resolve(parent.branch_name), updated_at: Time.current)
        events << "rewrote stack parent #{parent.slug} under #{child.slug}"
      end

      # The PR merges on GitHub (by anyone), with delete-branch-on-merge.
      def merge_externally!(job)
        pr = world.pull_request(job.pr_number)
        return unless pr&.open?

        world.merge_pull_request!(pr.number, force: true)
      end

      def set_pr_checks!(job, state)
        pr = world.pull_request(job.pr_number)
        pr.checks = state.to_s if pr
      end

      # ---- conditions and expectations ------------------------------------

      def pull_request_condition_matches?(condition)
        attrs = condition.to_h
        pr = world.pull_request(Job.find(attrs.fetch("job")).pr_number)
        return false unless pr
        return false if attrs["state"].present? && Array(attrs["state"]).map(&:to_s).exclude?(pr.merged ? "merged" : pr.state)
        return false if attrs["base"].present? && pr.base_branch != attrs["base"].to_s
        return false if attrs["mergeable_state"].present? && Array(attrs["mergeable_state"]).map(&:to_s).exclude?(peek_mergeable_state(pr))

        true
      end

      def expectations_match?(expected)
        expected = expected.to_h
        branches_match?(expected.fetch("branches", {})) && pull_requests_match?(expected.fetch("pull_requests", {}))
      end

      def fingerprint = world.fingerprint

      private

      attr_reader :job_ids

      def commit_work!(run)
        job = run.job
        checkout = checkout_for(job)
        world.commit!(parents: [ checkout.head ], patch: "job-#{job.id}-run-#{run.id}", paths: [ "job-#{job.id}.rb" ]).then do |commit|
          checkout.head = commit.id
        end
        job.update_columns(branch_name: checkout.branch) if job.branch_name.blank?
        run.update_columns(head_sha: checkout.head)
        nil
      end

      # Mirrors Steps::PrOpen's publication: the stack-base barrier (the real
      # StackBaseFreshness, with the same failure mapping as
      # PrOpen#ensure_stack_base_fresh!), then the push, then the PR.
      def open_or_update_pull_request!(run)
        job = run.job
        workflow = run.workflow
        checkout = checkout_for(job)
        base = RebaseTarget.branch_for(job: job, workflow: workflow)

        if StackBaseFreshness.applicable?(job, base)
          failure = ensure_stack_base_fresh!(workflow, job, checkout, base)
          return failure if failure
        end

        unless world.branch?(base)
          return Failure.new(failure_code: nil, problem_code: nil,
                             error_message: "pr_open: git fetch origin #{base} failed: couldn't find remote ref refs/heads/#{base}")
        end

        push!(checkout.branch, checkout.head)
        number = job.pr_number.presence || job.id + 10_000
        pr = world.pull_request(number)
        if pr.nil? || !pr.open?
          pr = world.open_pull_request!(number: number, head_branch: checkout.branch, base_branch: base, job_key: job.id)
        end
        run.update_columns(head_sha: checkout.head)
        job.update_columns(
          branch_name: checkout.branch,
          pr_number: number,
          pr_checks_state: pr.checks,
          pr_checks_sha: checkout.head,
          updated_at: Time.current
        )
        events << "pushed #{checkout.branch} at #{short(checkout.head)} for PR ##{number} (base #{pr.base_branch})"
        nil
      end

      def ensure_stack_base_fresh!(workflow, job, checkout, base)
        result = StackBaseFreshness.new(
          workflow: workflow,
          git: GitWorld::SimulatedGit.new(world, checkout),
          path: simulated_path(job),
          parent_ref: base,
          fetch_live: -> { world.resolve(base) },
          validator: -> { true },
          log: ->(message) { events << message }
        ).ensure_fresh!
        workflow.set_artifact!("stack_base_freshness", {
          "status" => result.status.to_s, "parent_ref" => result.parent_ref,
          "prepared_sha" => result.prepared_sha, "live_sha" => result.live_sha,
          "rebases" => result.rebases, "checked_at" => Time.current.iso8601
        }.compact)
        events << "stack base #{base} confirmed for #{job.slug} at #{short(result.live_sha)} (#{result.status})"
        nil
      rescue StackBaseFreshness::RebaseConflict => e
        workflow.set_artifact!(Steps::PrOpen::StackBaseRebaseConflict::ARTIFACT, e.evidence.merge("message" => e.message, "detected_at" => Time.current.iso8601))
        events << "stack base rebase conflict for #{job.slug}: #{e.evidence["conflicted_files"].to_a.map { |file| file["path"] }.join(", ")}"
        Failure.new(failure_code: Steps::PrOpen::StackBaseRebaseConflict::FAILURE_CODE, problem_code: "stack_base_rebase_conflict", error_message: e.message)
      rescue StackBaseFreshness::Error => e
        workflow.set_artifact!(StackBaseFreshness::AWAITING_ARTIFACT, e.evidence.merge(
          "reason" => e.class.name.demodulize.underscore, "message" => e.message, "detected_at" => Time.current.iso8601
        ))
        events << "awaiting stable base for #{job.slug}: #{e.message}"
        Failure.new(failure_code: "awaiting_stable_base", problem_code: "awaiting_stable_base", error_message: e.message)
      end

      # Mirrors Steps::AutoRebase / ::AutoRebase: a deterministic
      # `git rebase origin/<base>` of the source branch, pushed when it is
      # clean and changed; a conflict or a missing ref falls through to the
      # agent step.
      def auto_rebase!(run)
        job = run.job
        workflow = run.workflow
        base = RebaseTarget.branch_for(job: job, workflow: workflow)
        branch = RebaseTarget.source_branch_for(job: job, workflow: workflow)
        result = deterministic_rebase(job, branch, base)
        workflow.set_artifact!("auto_rebase_result", result)
        events << "auto_rebase #{branch} onto #{base}: #{result["reason"]}#{" (#{result["note"]})" if result["note"]}"
        if result["reason"] == ::AutoRebase::ALREADY_LANDED_REASON
          runner_close!(job)
          skip_next!(run, "agent_rebase", "auto_rebase found the work already on the base; nothing to rebase")
        elsif result["succeeded"]
          skip_next!(run, "agent_rebase", "auto_rebase already succeeded; agent rebase not needed")
        else
          workflow.set_artifact!("auto_rebase_reason", result["reason"])
        end
        nil
      end

      # The agent resolves whatever conflicts the replay meets; it cannot
      # fetch a branch that does not exist.
      def agent_rebase!(run)
        job = run.job
        workflow = run.workflow
        base = RebaseTarget.branch_for(job: job, workflow: workflow)
        branch = RebaseTarget.source_branch_for(job: job, workflow: workflow)
        return missing_ref_failure("agent_rebase", base) unless world.branch?(base)
        return missing_ref_failure("agent_rebase", branch) unless world.branch?(branch)

        tip = world.rebase(head: branch, onto: base, resolve: true).tip
        @pending_pushes[workflow.id][branch] = tip
        checkout_for(job).head = tip if branch == job.branch_name
        run.update_columns(head_sha: tip)
        events << "agent_rebase resolved #{branch} onto #{base} at #{short(tip)}"
        nil
      end

      # Mirrors Steps::StackAutoRebase over the entries the real
      # StackRebasePlan recorded: each entry is rebased onto *its recorded
      # base_branch*, so an entry naming a deleted branch fails like a fetch
      # of a missing ref and stops the deterministic pass.
      def stack_auto_rebase!(run)
        workflow = run.workflow
        entries = Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT))
        results = []
        pending = []
        entries.each do |entry|
          stack_job = Job.find_by(id: entry["job_id"])
          result = deterministic_rebase(stack_job, entry["branch_name"], entry["base_branch"])
          results << entry.merge("result" => result)
          events << "stack_auto_rebase #{entry["branch_name"]} onto #{entry["base_branch"]}: #{result["reason"]}#{" (#{result["note"]})" if result["note"]}"
          runner_close!(stack_job) if result["reason"] == ::AutoRebase::ALREADY_LANDED_REASON
          next if result["succeeded"]

          pending << entry
          break
        end
        processed = results.map { |entry| entry["job_id"] }
        pending.concat(entries.reject { |entry| processed.include?(entry["job_id"]) })
        workflow.set_artifact!(StackRebasePlan::RESULTS_ARTIFACT, results)
        workflow.set_artifact!(StackRebasePlan::AGENT_PENDING_ARTIFACT, pending)
        skip_next!(run, "stack_agent_rebase", "stack auto-rebase already succeeded") if pending.empty?
        nil
      end

      # Mirrors Steps::StackAgentRebase: fetch every pending branch and base
      # (a missing one fails the step), then the agent rebases each onto its
      # base, resolving conflicts; stack_force_push publishes them.
      def stack_agent_rebase!(run)
        workflow = run.workflow
        pending = Array(workflow.artifact(StackRebasePlan::AGENT_PENDING_ARTIFACT))
        pending.each do |entry|
          [ entry["branch_name"], entry["base_branch"] ].each do |ref|
            return missing_ref_failure("stack_agent_rebase", ref) unless world.branch?(ref)
          end
        end
        pushes = pending.map do |entry|
          pre = world.resolve(entry["branch_name"])
          tip = world.rebase(head: entry["branch_name"], onto: @pending_pushes[workflow.id][entry["base_branch"]] || entry["base_branch"], resolve: true).tip
          @pending_pushes[workflow.id][entry["branch_name"]] = tip
          entry.merge("pre_sha" => pre, "post_sha" => tip)
        end
        workflow.set_artifact!(StackRebasePlan::AGENT_PUSHES_ARTIFACT, pushes)
        events << "stack_agent_rebase resolved #{pushes.map { |entry| entry["branch_name"] }.join(", ")}"
        nil
      end

      def push_pending!(run)
        pushes = @pending_pushes.delete(run.workflow.id).to_h
        pushes.each { |branch, sha| push!(branch, sha) }
        events << "pushed #{pushes.keys.join(", ")}" if pushes.any?
        nil
      end

      def merge_job!(run)
        job = run.job
        pr = world.pull_request(job.pr_number)
        return nil unless pr&.open?

        merged = world.merge_pull_request!(pr.number)
        job.update_columns(landed_sha: merged)
        events << "merged PR ##{pr.number} into #{pr.base_branch} at #{short(merged)}"
        nil
      rescue GitWorld::MergeConflict => e
        Failure.new(failure_code: nil, problem_code: nil, error_message: "auto_merge: #{e.message}")
      end

      # The train integrated (and resolved) its members, so each member PR
      # merges in train order.
      def merge_train!(run, outcome)
        return nil if outcome.is_a?(Hash) && outcome["unverified_members"].present?

        train = MergeTrain.find_by(id: run.workflow.artifact("merge_train_id"))
        members = train&.member_jobs&.to_a.presence || run.workflow.work_unit&.member_jobs&.to_a || [ run.job ]
        members.compact.each do |member|
          pr = world.pull_request(member.pr_number)
          next unless pr&.open?

          merged = world.merge_pull_request!(pr.number, force: true)
          events << "merge train merged PR ##{pr.number} into #{pr.base_branch} at #{short(merged)}"
        end
        nil
      end

      def deterministic_rebase(job, branch, base)
        return { "succeeded" => false, "reason" => "no_branch" } if branch.blank?

        [ base, branch ].each do |ref|
          next if world.branch?(ref)

          return { "succeeded" => false, "reason" => "error", "note" => "git fetch failed: couldn't find remote ref refs/heads/#{ref}" }
        end

        pre = world.resolve(branch)
        base_sha = world.resolve(base)
        result = world.rebase(head: branch, onto: base)
        return { "succeeded" => false, "reason" => "conflict", "pre_sha" => pre, "base_sha" => base_sha } if result.conflicted?

        if result.tip == pre
          { "succeeded" => true, "reason" => "rebased", "note" => "no-op (already up-to-date)", "changed" => false, "pre_sha" => pre, "post_sha" => pre, "base_sha" => base_sha }
        elsif world.range(result.tip, exclude: [ base_sha ]).empty?
          { "succeeded" => true, "reason" => ::AutoRebase::ALREADY_LANDED_REASON, "changed" => false, "pre_sha" => pre, "post_sha" => result.tip, "base_sha" => base_sha }
        else
          push!(branch, result.tip)
          checkout_for(job).head = result.tip if job && branch == job.branch_name
          { "succeeded" => true, "reason" => "rebased", "changed" => true, "pre_sha" => pre, "post_sha" => result.tip, "base_sha" => base_sha }
        end
      end

      def push!(branch, sha)
        world.set_branch!(branch, sha)
        world.pushed!(branch)
      end

      def missing_ref_failure(step, ref)
        events << "#{step}: couldn't find remote ref #{ref}"
        Failure.new(failure_code: nil, problem_code: nil, error_message: "#{step}: git fetch failed: couldn't find remote ref refs/heads/#{ref}")
      end

      # The Job's local workspace. A Job with no branch yet branches off the
      # base it will be published against.
      def checkout_for(job)
        branch = job.branch_name.presence || "syrus/simulated-#{job.id}"
        checkout = world.checkout(job.id, branch: branch)
        checkout.branch ||= branch
        checkout.head ||= world.resolve(branch) || world.resolve(RebaseTarget.branch_for(job: job)) || world.resolve!(world.default_branch)
        checkout
      end

      def simulated_path(job) = "simulated-git://job-#{job.id}"

      def runner_close!(job)
        job.close_with_reason!("pr_merged") if job&.may_close?
      end

      def skip_next!(run, kind, reason)
        next_step = run.step.next_step
        return unless next_step&.kind == kind && next_step.may_skip?

        next_step.skip_with_reason!(reason)
      end

      def pull_request_for!(job)
        world.pull_request(job.pr_number) || raise(ArgumentError, "#{job.slug} has no simulated pull request")
      end

      # Reading mergeability for a condition must not consume one of a PR's
      # scripted unknown reads.
      def peek_mergeable_state(pr)
        reads = pr.unknown_reads
        world.mergeability(pr).last
      ensure
        pr.unknown_reads = reads
      end

      def branches_match?(expected)
        expected.all? do |branch, attrs|
          attrs = attrs.to_h
          exists = world.branch?(branch)
          next false if attrs.key?("exists") && exists != attrs["exists"]
          next true unless exists

          Array(attrs["descends_from"]).all? { |ref| world.resolve(ref) && world.ancestor?(ref, branch) } &&
            Array(attrs["excludes"]).none? { |ref| world.resolve(ref) && world.ancestor?(ref, branch) } &&
            Array(attrs["contains_patches"]).all? { |patch| world.range(branch).any? { |commit| commit.patch == patch.to_s } }
        end
      end

      def pull_requests_match?(expected)
        expected.all? do |job_id, attrs|
          attrs = attrs.is_a?(Hash) ? attrs : { "state" => attrs }
          pr = world.pull_request(Job.find(job_id).pr_number)
          next false unless pr
          next false if attrs["state"].present? && Array(attrs["state"]).map(&:to_s).exclude?(pr.merged ? "merged" : pr.state)

          attrs["base"].blank? || pr.base_branch == attrs["base"].to_s
        end
      end

      def branch_from(attrs)
        return attrs["branch"].to_s if attrs["branch"].present?

        Job.find(attrs.fetch("job")).branch_name.presence || raise(ArgumentError, "job #{attrs["job"]} has no branch")
      end

      def job_from(value)
        Job.find(value.is_a?(Hash) ? value.fetch("job") : value)
      end

      def short(sha) = sha.to_s.first(8).presence || "none"

      def content_provider_class
        world_ref = world
        Class.new do
          include Syrus::Plugin::RepositoryContentProvider

          define_singleton_method(:provider_key) { "simulation_git_world" }
          define_singleton_method(:display_name) { "Simulation git world" }
          define_singleton_method(:role) { :replica }
          define_singleton_method(:available_for?) { |_repository| true }
          define_singleton_method(:build) { |repository:, user:| new }

          define_method(:resolve) do |ref, max_age:|
            sha = world_ref.resolve(ref)
            raise RepositoryContent::UnknownRevision, "unknown simulated ref #{ref}" unless sha

            RepositoryContent::Revision.new(id: sha, ref: ref, observed_at: Time.current)
          end
          define_method(:divergence) do |base_id, head_id|
            raise RepositoryContent::UnknownRevision, "unknown simulated revision" unless world_ref.commit(base_id) && world_ref.commit(head_id)

            RepositoryContent::Divergence.new(
              ahead: world_ref.range(head_id, exclude: [ base_id ]).size,
              behind: world_ref.range(base_id, exclude: [ head_id ]).size
            )
          end
          define_method(:relation) do |base_id, head_id|
            next :identical if base_id == head_id
            next :ahead if world_ref.ancestor?(base_id, head_id)
            next :behind if world_ref.ancestor?(head_id, base_id)

            :diverged
          end
          define_method(:tree) { |_revision_id| raise RepositoryContent::Unsupported, "the simulated git world has no trees" }
          define_method(:read) { |_revision_id, _path| raise RepositoryContent::Unsupported, "the simulated git world has no blobs" }
        end
      end
    end
  end
end
