require "set"

module Unlanding
  class Create
    class Ineligible < StandardError; end

    Plan = Data.define(:original, :affected, :base_sha, :commit_shas, :files, :dependents,
                       :deployment_stages, :warnings) do
      def to_h
        {
          subject: original.slug,
          affected:,
          base_sha:,
          commits: commit_shas,
          files:,
          dependents:,
          deployment_stages:,
          warnings:
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
      original.with_lock do
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
      Plan.new(
        original:, affected: affected_slugs, base_sha:, commit_shas: shas,
        files: changed_files(git, clone, shas),
        dependents: dependent_slugs,
        deployment_stages: deployment_stage_reach,
        warnings: plan_warnings
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
      jobs.sort_by do |job|
        depth = 0
        cursor = job
        seen = Set.new
        while (parent_id = cursor.dependencies.find(&:depends_on_job_id?)&.depends_on_job_id) && by_id[parent_id] && seen.add?(parent_id)
          depth += 1
          cursor = by_id.fetch(parent_id)
        end
        [ depth, job.id ]
      end
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
      job_dependents = Job.where(id: JobDependency.where(depends_on_job_id: jobs.map(&:id)).select(:job_id)).pluck(:slug)
      epic_dependents = if original.is_a?(Epic)
        original.dependent_epics.pluck(:slug) +
          Job.where(id: JobDependency.where(depends_on_epic_id: original.id).select(:job_id)).pluck(:slug)
      else
        Epic.where(id: EpicDependency.where(depends_on_job_id: original.id).select(:epic_id)).pluck(:slug)
      end
      (job_dependents + epic_dependents).compact.uniq.sort
    end

    def affected_slugs
      return [ original.slug ] if original.is_a?(Job)

      [ original.slug, *original.work_jobs.order(:id).map(&:slug) ]
    end

    def deployment_stage_reach
      jobs = original.is_a?(Epic) ? original.work_jobs : [ original ]
      jobs.each_with_object({}) do |job, result|
        stages = job.deployment_stage_statuses.order(:reached_at).pluck(:stage_name)
        result[job.slug] = stages if stages.any?
      end
    end

    def plan_warnings
      warnings = []
      warnings << "Downstream dependent work exists" if dependent_slugs.any?
      warnings << "Landed work reached deployment stages" if deployment_stage_reach.any?
      warnings
    end

    def workflow_agent_provider
      return original.workflow_agent_provider if original.is_a?(Job)

      original.work_jobs.filter_map(&:workflow_agent_provider).first
    end
  end
end
