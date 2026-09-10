# Resolves the optional visual_review loop configured in `.syrus.yml`,
# falling back to the instance-wide `visual_review` Feature flag default
# when the repository hasn't configured (or couldn't fetch) a visual_review
# block, or configured one without an explicit `enabled` key.
#
# Thin adapter over RepoDefaultBranchSyrusYml, which owns the actual GitHub
# fetch and SyrusYml parse (shared with RepoAdversarialReviewPlan,
# RepoGradeLoopPlan, RepoReviewPlanPlan, and RepoCoveragePlanReader so
# Workflows::Base resolves the repository's default-branch config once per
# workflow instantiation instead of each plan fetching it independently).
require "tmpdir"

class RepoVisualReviewPlan
  Result = Data.define(:enabled, :rounds, :source, :note) do
    def enabled?
      enabled
    end
  end

  def self.for_job(job, loaded: RepoDefaultBranchSyrusYml.for_job(job))
    root_plan = from_syrus_yml(loaded)
    project_plan = from_default_branch_projects(job)
    return root_plan unless project_plan

    merge(root_plan, project_plan)
  end

  def self.from_syrus_yml(loaded)
    return instance_default(source: loaded.source, note: loaded.note) unless loaded.config

    review = loaded.config.visual_review
    return instance_default(source: loaded.source, note: "no visual_review configured") unless review

    enabled = review.enabled.nil? ? Feature.visual_review_enabled? : review.enabled
    Result.new(enabled: enabled, rounds: review.rounds, source: loaded.source, note: nil)
  end

  def self.instance_default(source:, note:)
    Result.new(enabled: Feature.visual_review_enabled?, rounds: SyrusYml::DEFAULT_VISUAL_REVIEW_ROUNDS, source: source, note: note)
  end

  def self.merge(root_plan, project_plan)
    enabled = root_plan.enabled? || project_plan.enabled?
    rounds = [ root_plan, project_plan ].select(&:enabled?).map(&:rounds).max || SyrusYml::DEFAULT_VISUAL_REVIEW_ROUNDS
    source = [ root_plan.source, project_plan.source ].compact_blank.uniq.join(", ")
    note = enabled ? nil : root_plan.note || project_plan.note

    Result.new(enabled: enabled, rounds: rounds, source: source, note: note)
  end

  def self.from_default_branch_projects(job)
    return nil unless job.respond_to?(:repository)

    repository = job.repository
    bare_clone_path = RepositoryBareClone.path_for(repository)
    return nil unless bare_clone_path.directory?

    Dir.mktmpdir("syrus-visual-review-plan") do |dir|
      GitRunner.new.run(
        "--git-dir", bare_clone_path.to_s,
        "--work-tree", dir,
        "checkout", "-f", repository.default_branch, "--", ".",
        chdir: dir
      )
      graph = TargetGraph::Compiler.compile(Pathname.new(dir))
      enabled_project_rounds = graph.projects.values
        .reject(&:root?)
        .select(&:preview)
        .filter_map { |project| rounds_for_enabled_project(project) }
      next nil if enabled_project_rounds.empty?

      Result.new(enabled: true, rounds: enabled_project_rounds.max, source: "project .syrus.yml", note: nil)
    end
  rescue StandardError => e
    Rails.logger.warn("[RepoVisualReviewPlan] project visual_review unavailable for #{job.try(:slug) || job.inspect}: #{e.class}: #{e.message}")
    nil
  end

  def self.rounds_for_enabled_project(project)
    config = project.visual_review
    enabled = config&.enabled.nil? ? Feature.visual_review_enabled? : config.enabled
    return nil unless enabled

    config&.rounds || SyrusYml::DEFAULT_VISUAL_REVIEW_ROUNDS
  end
end
