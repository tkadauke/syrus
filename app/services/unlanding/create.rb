module Unlanding
  class Create
    class Ineligible < StandardError; end

    Plan = Data.define(:original, :affected, :base_sha, :commit_shas, :files, :dependents,
                       :deployment_stages, :warnings, :graders) do
      def to_h
        {
          subject: original.slug,
          affected:,
          base_sha:,
          commits: commit_shas,
          files:,
          dependents:,
          deployment_stages:,
          warnings:,
          graders:
        }
      end
    end

    def self.plan!(original:, user: nil)
      new(original:, user:, agent_provider: nil).plan!
    end

    def self.call!(original:, user: nil, agent_provider: nil)
      new(original:, user:, agent_provider:).call!
    end

    def initialize(original:, user:, agent_provider:)
      @original = original
      @user = user || original.user
      @agent_provider = agent_provider
    end

    def call!
      original.unland_lock_record.with_lock do
        plan = plan!

        rollback = Job.create!(
          user:, repository: original.repository, kind: "direct",
          issue_title: "Rollback #{original.slug}: #{original.title}",
          issue_body: "Compensating rollback for #{original.slug}. The original landing remains closed and unchanged.",
          rollback_of: original.is_a?(Job) ? original : nil,
          rollback_epic: original.is_a?(Epic) ? original : nil,
          priority: "urgent",
          agent_provider: agent_provider.presence || workflow_agent_provider
        )
        workflow = WorkUnits::Launcher.instantiate(
          kind: "unland", job: rollback,
          artifacts: {
            "unland_commit_shas" => plan.commit_shas,
            "unland_base_sha" => plan.base_sha,
            "unland_plan" => plan.to_h.deep_stringify_keys
          },
          agent_provider:, source_type: "unlanding"
        )
        rollback.start_running! if rollback.may_start_running?
        WorkUnits::Launcher.start!(workflow)
        rollback
      end
    end

    private

    attr_reader :original, :user, :agent_provider

    def plan!
      validate_original!
      shas, base_sha, git, clone = verified_commits
      dependents = dependent_slugs
      deployment_stages = deployment_stage_reach
      Plan.new(
        original:, affected: affected_slugs, base_sha:, commit_shas: shas,
        files: changed_files(git, clone, shas),
        dependents:,
        deployment_stages:,
        warnings: plan_warnings(dependents, deployment_stages),
        graders: unland_graders(clone)
      )
    end

    public :plan!

    def validate_original!
      if original.is_a?(Job)
        validate_job!
      elsif original.is_a?(Epic)
        validate_epic!
      else
        raise Ineligible, "only Jobs and Epics can be unlanded"
      end
    end

    def validate_job!
      unless landed_job?(original)
        raise Ineligible, "only successfully landed Jobs can be unlanded"
      end
      raise Ineligible, "Job was already successfully unlanded" if original.unlanded_by
      if original.rollback_jobs.where(state: active_states).exists?
        raise Ineligible, "an unland is already active for this Job"
      end
      if original.epic&.rollback_jobs&.where(state: active_states)&.exists?
        raise Ineligible, "an Epic unland is already active for this Job"
      end
    end

    def validate_epic!
      children = original.work_jobs.to_a
      raise Ineligible, "only landed Epics can be unlanded" if children.empty?
      unless children.all? { |job| landed_job?(job) }
        raise Ineligible, "Epic has partial or mixed landing; every child must be successfully landed"
      end
      reverted = children.select(&:unlanded_by)
      raise Ineligible, "Epic contains previously reverted children: #{reverted.map(&:slug).join(', ')}" if reverted.any?
      raise Ineligible, "Epic was already successfully unlanded" if original.unlanded_by
      if original.rollback_jobs.where(state: active_states).exists?
        raise Ineligible, "an unland is already active for this Epic"
      end
      if Job.where(rollback_of_id: children.map(&:id), state: active_states).exists?
        raise Ineligible, "an unland is already active for an Epic child"
      end
    end

    def landed_job?(job)
      job.closed? && Job::SUCCESSFUL_CLOSURE_REASONS.include?(job.closure_reason) && job.landed_sha.present?
    end

    def active_states
      Job::STATES - (Job::TERMINAL_STATES + %w[failed])
    end

    def verified_commits
      rows = commit_rows
      raise Ineligible, "landed commits are missing" if rows.empty?

      clone = RepositoryBareClone.new(original.repository)
      clone.sync!(user: user)
      git = GitRunner.new
      base = git.run("rev-parse", "refs/heads/#{original.repository.default_branch}", chdir: clone.path.to_s).strip
      shas = rows.map(&:sha)
      duplicates = shas.tally.select { |_sha, count| count > 1 }.keys
      raise Ineligible, "overlapping/shared commit ownership: #{duplicates.join(', ')}" if duplicates.any?
      selected_owners = rows.map { |row| [ row.landable_type, row.landable_id ] }.uniq
      shared = LandedCommit.where(sha: shas).reject do |row|
        selected_owners.include?([ row.landable_type, row.landable_id ])
      end.map(&:sha).uniq
      raise Ineligible, "overlapping/shared commit ownership: #{shared.join(', ')}" if shared.any?
      shas.each do |sha|
        git.run("merge-base", "--is-ancestor", sha, base, chdir: clone.path.to_s)
        parents = git.run("rev-list", "--parents", "-n", "1", sha, chdir: clone.path.to_s).split
        raise Ineligible, "landed commit #{sha} is a merge commit with an ambiguous rollback mainline" if parents.length > 2
      rescue GitRunner::GitError
        raise Ineligible, "landed commit #{sha} is not safely reachable from current default branch"
      end
      [ shas, base, git, clone ]
    rescue GitRunner::GitError => e
      raise Ineligible, "landed commits could not be verified: #{e.message}"
    end


    def commit_rows
      return LandedCommit.where(landable: original, kind: "implementation").order(:position, :id).to_a if original.is_a?(Job)

      train = MergeTrain.where(epic: original, state: "succeeded").order(:finished_at, :id).last
      if train
        member_ids = train.members.order(:position).pluck(:job_id)
        unless member_ids.sort == original.work_jobs.pluck(:id).sort
          raise Ineligible, "Epic merge-train membership does not match its landed children"
        end
        rows = member_ids.flat_map do |job_id|
          LandedCommit.where(landable_type: "Job", landable_id: job_id, kind: "implementation").order(:position, :id).to_a
        end
        rows + LandedCommit.where(landable: original, kind: "reconcile").order(:position, :id).to_a
      else
        ordered_epic_jobs.flat_map do |job|
          LandedCommit.where(landable: job, kind: "implementation").order(:position, :id).to_a
        end
      end
    end

    def ordered_epic_jobs
      jobs = original.work_jobs.includes(:dependencies).to_a
      by_id = jobs.index_by(&:id)
      parents = jobs.to_h do |job|
        [ job.id, job.dependencies.filter_map(&:depends_on_job_id).select { |id| by_id.key?(id) } ]
      end
      children = Hash.new { |hash, key| hash[key] = [] }
      parents.each { |job_id, parent_ids| parent_ids.each { |parent_id| children[parent_id] << job_id } }
      first_commit_id = LandedCommit.where(landable_type: "Job", landable_id: by_id.keys, kind: "implementation")
                                    .group(:landable_id).minimum(:id)
      sort_key = ->(job_id) { [ first_commit_id.fetch(job_id, Float::INFINITY), job_id ] }
      ready = parents.select { |_job_id, parent_ids| parent_ids.empty? }.keys.sort_by(&sort_key)
      ordered = []
      until ready.empty?
        job_id = ready.shift
        ordered << by_id.fetch(job_id)
        children[job_id].each do |child_id|
          parents.fetch(child_id).delete(job_id)
          ready << child_id if parents.fetch(child_id).empty?
        end
        ready.sort_by!(&sort_key)
      end
      raise Ineligible, "Epic child dependency graph contains a cycle" unless ordered.size == jobs.size

      ordered
    end

    def changed_files(git, clone, shas)
      shas.flat_map do |sha|
        git.run("diff-tree", "--no-commit-id", "--name-only", "-r", sha, chdir: clone.path.to_s).lines.map(&:strip)
      end.reject(&:blank?).uniq.sort
    rescue GitRunner::GitError => e
      raise Ineligible, "landed commit files could not be inspected: #{e.message}"
    end

    def dependent_slugs
      jobs = original.is_a?(Epic) ? original.work_jobs : [ original ]
      job_ids = jobs.map(&:id)
      dependency_scope = JobDependency.where(depends_on_job_id: job_ids)
      dependency_scope = dependency_scope.where.not(job_id: job_ids) if original.is_a?(Epic)
      job_dependents = Job.where(id: dependency_scope.pluck(:job_id)).map(&:slug)
      epic_dependents = if original.is_a?(Epic)
        original.dependent_epics.map(&:slug) +
          Job.where(id: JobDependency.where(depends_on_epic_id: original.id).pluck(:job_id)).map(&:slug)
      else
        Epic.where(id: EpicDependency.where(depends_on_job_id: original.id).select(:epic_id)).map(&:slug)
      end
      (job_dependents + epic_dependents).compact.uniq.sort
    end

    def affected_slugs
      return [ original.slug ] if original.is_a?(Job)

      [ original.slug, *original.work_jobs.order(:id).map(&:slug) ]
    end

    def deployment_stage_reach
      jobs = original.is_a?(Epic) ? original.work_jobs.to_a : [ original ]
      slugs = jobs.to_h { |job| [ job.id, job.slug ] }
      JobDeploymentStageStatus.where(job_id: slugs.keys).order(:reached_at).pluck(:job_id, :stage_name)
                              .each_with_object({}) do |(job_id, stage_name), result|
        (result[slugs.fetch(job_id)] ||= []) << stage_name
      end
    end

    def plan_warnings(dependents = dependent_slugs, stages = deployment_stage_reach)
      warnings = []
      warnings << "Downstream dependent work exists" if dependents.any?
      warnings << "Landed work reached deployment stages" if stages.any?
      warnings
    end

    def unland_graders(clone)
      plan = RepoGradePlan.for(clone.path)
      selected = LandingGraderPlan.effective(
        plan, trigger_kind: "unland", iteration: 1, repository: original.repository,
        job: original.is_a?(Job) ? original : original.work_jobs.first
      ).graders.select(&:required).map(&:name)
      selected
    rescue SyrusYml::ParseError => e
      raise Ineligible, "unland graders could not be selected: #{e.message}"
    end

    def workflow_agent_provider
      return original.workflow_agent_provider if original.is_a?(Job)

      original.work_jobs.filter_map(&:workflow_agent_provider).first
    end
  end
end
