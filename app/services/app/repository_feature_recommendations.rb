require "shellwords"

module App
  class RepositoryFeatureRecommendations
    include Rails.application.routes.url_helpers

    VERSION = 1
    MAX_RECOMMENDATIONS = 3
    JOB_ACTIONS = {
      "visual_review" => {
        title: "Configure visual review",
        prompt: <<~PROMPT.strip
          Configure this repository for Syrus visual review.

          Update `.syrus.yml` so browser-facing changes can be reviewed by the visual reviewer. Add or refine `preview:` if needed, enable `visual_review`, choose conservative `when_files_changed` globs for the browser app surface, and add useful `seed_notes` when preview setup needs seed or login context. Keep the change scoped to Syrus configuration and any minimal preview seed documentation required for visual review to run reliably.
        PROMPT
      },
      "preview_seed_data" => {
        title: "Seed preview demo data",
        prompt_template_id: "configure-preview-seed-data"
      },
      "syrus_prepare" => {
        title: "Configure Syrus build dependencies",
        prompt_template_id: "configure-syrus-prep"
      },
      "github_actions_ci" => {
        title: "Add GitHub Actions CI",
        prompt_template_id: "add-github-actions-ci"
      },
      "delivery_tracks" => {
        title: "Configure delivery tracks",
        prompt: <<~PROMPT.strip
          Configure Syrus delivery tracks for this repository.

          Inspect the branch layout and update `.syrus.yml` with a focused `delivery:` configuration only if the repository uses a develop/release/fork workflow. Include promotion, hotfix sync, or upstream export settings that match the existing branch model. Keep the change scoped and avoid enabling silent ref movement unless the repository shape clearly supports it.
        PROMPT
      }
    }.freeze
    TOGGLE_ACTIONS = {
      "enable_prepare" => { "prepare_enabled" => true },
      "enable_pr_cost_footer" => { "pr_cost_footer_enabled" => true },
      "enable_main_branch_health" => { "main_branch_health_enabled" => true }
    }.freeze

    def self.for(repository:, user:)
      new(repository: repository, user: user).recommendations
    end

    def self.job_action(action_id)
      action = JOB_ACTIONS[action_id.to_s]
      return nil unless action

      prompt = if action[:prompt_template_id]
        PromptTemplate.find(action[:prompt_template_id])&.prompt
      else
        action[:prompt]
      end
      return nil if prompt.blank?

      action.merge(prompt: prompt)
    end

    def self.toggle_attributes(action_id)
      TOGGLE_ACTIONS[action_id.to_s]
    end

    def initialize(repository:, user:)
      @repository = repository
      @user = user
    end

    def recommendations
      candidates.first(MAX_RECOMMENDATIONS)
    end

    private

    attr_reader :repository, :user

    def candidates
      [
        visual_review,
        preview_seed_data,
        syrus_prepare,
        github_actions_ci,
        main_branch_health,
        main_branch_repair,
        auto_merge,
        external_pr_ingestion,
        fork_auto_sync,
        delivery_tracks,
        pr_cost_footer
      ].compact.concat(plugin_candidates)
       .sort_by { |entry| entry.fetch(:order) }
       .map { |entry| entry.except(:order) }
    end

    def visual_review
      return if visual_review_enabled?
      return unless preview_configured? || browser_app?

      recommendation(
        id: "visual_review",
        title: "Add visual review",
        body: "Let Syrus run browser QA on UI diffs before graders and PR review.",
        tone: "blue",
        category: "quality",
        order: 10,
        cta: job_cta("Configure", "visual_review"),
        secondary_path: docs_path("visual_review")
      )
    end

    def preview_seed_data
      return unless preview_configured?
      return if preview_seed_configured? && preview_seed_notes_present?
      return unless latest_preview_seedish_failure? || !preview_seed_notes_present?

      recommendation(
        id: "preview_seed_data",
        title: "Improve preview seed data",
        body: "Give previews reliable demo state so visual checks start from a useful screen.",
        tone: "amber",
        category: "setup",
        order: 20,
        cta: job_cta("Create setup job", "preview_seed_data"),
        secondary_path: repository_scheduled_tasks_path(repository)
      )
    end

    def syrus_prepare
      if !repository.prepare_enabled?
        return recommendation(
          id: "syrus_prepare",
          title: "Enable prepare",
          body: "Run dependency setup before agent and grader steps for this repository.",
          tone: "amber",
          category: "setup",
          order: 30,
          cta: toggle_cta("Enable", "enable_prepare"),
          secondary_path: edit_repository_path(repository, anchor: "automation")
        )
      end

      return unless config_missing? || parsed_config&.prepare.nil?

      recommendation(
        id: "syrus_prepare",
        title: "Pin Syrus prepare commands",
        body: "Add explicit setup commands so onboarding does not rely on lockfile guesses.",
        tone: "amber",
        category: "setup",
        order: 31,
        cta: job_cta("Create setup job", "syrus_prepare"),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end

    def github_actions_ci
      return unless repository.ci_health_unknown? || repository.ci_health_not_configured?
      return if github_actions_workflow?

      recommendation(
        id: "github_actions_ci",
        title: "Add GitHub Actions CI",
        body: "Publish a baseline CI workflow so Syrus can trust pull request and main-branch checks.",
        tone: "amber",
        category: "setup",
        order: 40,
        cta: job_cta("Create CI job", "github_actions_ci"),
        secondary_path: "https://github.com/#{repository.slug}/actions"
      )
    end

    def main_branch_health
      return if repository.main_branch_health_enabled?
      return unless health_signals?

      recommendation(
        id: "main_branch_health",
        title: "Track main branch health",
        body: "Monitor default-branch CI and graders so regressions are visible before more work lands.",
        tone: "blue",
        category: "quality",
        order: 50,
        cta: toggle_cta("Enable", "enable_main_branch_health"),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end

    def main_branch_repair
      return unless repository.main_branch_health_enabled?
      return if repository.main_branch_repair_enabled?
      return unless health_signals?

      recommendation(
        id: "main_branch_repair",
        title: "Enable main repair",
        body: "Let Syrus file focused repair work when the default branch breaks.",
        tone: "blue",
        category: "quality",
        order: 60,
        cta: link_cta("Review setting", edit_repository_path(repository, anchor: "automation")),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end

    def auto_merge
      return if repository.auto_merge_enabled?
      return unless repository.main_health == "healthy" || (repository.ci_health_healthy? && repository.grader_health_healthy?)
      return if early_setup?

      recommendation(
        id: "auto_merge",
        title: "Review auto-merge",
        body: "The repository has healthy signals, so approved work can use the landing queue.",
        tone: "green",
        category: "automation",
        order: 70,
        cta: link_cta("Open settings", edit_repository_path(repository, anchor: "auto-merge")),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end

    def external_pr_ingestion
      return if repository.external_pr_ingestion_enabled?
      return unless repository.fork? || external_pr_signals?

      recommendation(
        id: "external_pr_ingestion",
        title: "Ingest external PRs",
        body: "Bring non-Syrus pull requests into the same review, grading, and landing flow.",
        tone: "blue",
        category: "automation",
        order: 80,
        cta: link_cta("Open settings", edit_repository_path(repository, anchor: "automation")),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end


    def fork_auto_sync
      return unless repository.fork_syncable?
      return if repository.fork_auto_sync_enabled?

      recommendation(
        id: "fork_auto_sync",
        title: "Keep fork in sync",
        body: "Auto-sync the fork default branch so health checks and new work start from current upstream code.",
        tone: "gray",
        category: "maintenance",
        order: 100,
        cta: link_cta("Open settings", edit_repository_path(repository, anchor: "automation")),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end

    def delivery_tracks
      return if delivery_configured?
      return unless delivery_shape?

      recommendation(
        id: "delivery_tracks",
        title: "Configure delivery tracks",
        body: "Model develop, release, hotfix, or upstream export flow explicitly in Syrus.",
        tone: "gray",
        category: "delivery",
        order: 110,
        cta: job_cta("Create config job", "delivery_tracks"),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end

    def pr_cost_footer
      return if repository.pr_cost_footer_enabled?

      recommendation(
        id: "pr_cost_footer",
        title: "Show PR cost footer",
        body: "Add run cost visibility to Syrus-authored pull requests.",
        tone: "gray",
        category: "cost",
        order: 120,
        cta: toggle_cta("Enable", "enable_pr_cost_footer"),
        secondary_path: edit_repository_path(repository, anchor: "automation")
      )
    end

    # A plugin recommending its own feature. Core supplies the dismissal key
    # so the shape stays consistent, and skips a provider that raises rather
    # than failing the whole repository page over one suggestion.
    def plugin_candidates
      Syrus::PluginRegistry.providers_for(:repository_recommendation).flat_map do |provider|
        Array(provider.repository_recommendations(repository: repository, user: user)).map do |entry|
          entry = entry.to_h.symbolize_keys
          next if entry[:id].blank? || entry[:order].blank?

          entry.merge(dismissal_key: "repository:#{repository.id}:feature_recommendation:#{entry[:id]}:v#{VERSION}")
        end.compact
      end
    rescue StandardError => e
      Rails.logger.warn("[RepositoryFeatureRecommendations] plugin recommendations failed: #{e.class}: #{e.message}")
      []
    end

    def recommendation(id:, title:, body:, tone:, category:, order:, cta:, secondary_path:)
      {
        id: id,
        title: title,
        body: body,
        tone: tone,
        category: category,
        cta: cta,
        dismissal_key: "repository:#{repository.id}:feature_recommendation:#{id}:v#{VERSION}",
        secondary_path: secondary_path,
        order: order
      }
    end

    def job_cta(label, action_id)
      {
        label: label,
        kind: "job",
        action_id: action_id,
        method: "POST",
        path: "/api/v1/app/repositories/#{repository.id}/recommendations/#{action_id}"
      }
    end

    def toggle_cta(label, action_id)
      {
        label: label,
        kind: "toggle",
        action_id: action_id,
        method: "POST",
        path: "/api/v1/app/repositories/#{repository.id}/recommendations/#{action_id}"
      }
    end

    def link_cta(label, path)
      {
        label: label,
        kind: "link",
        path: path,
        method: "GET"
      }
    end

    def docs_path(anchor)
      "/docs/#{anchor}"
    end

    def parsed_config
      return @parsed_config if defined?(@parsed_config)

      content = syrus_yml_content
      @parsed_config = content.present? ? SyrusYml.new(content).parse : nil
    rescue SyrusYml::ParseError => e
      Rails.logger.warn("[RepositoryFeatureRecommendations] invalid .syrus.yml for #{repository.slug}: #{e.message}")
      @parsed_config = nil
    end

    def config_missing?
      bare_clone_path.exist? && syrus_yml_content.blank?
    end

    def syrus_yml_content
      return @syrus_yml_content if defined?(@syrus_yml_content)
      return @syrus_yml_content = nil unless bare_clone_path.exist?

      @syrus_yml_content = git_show("HEAD:.syrus.yml")
    end

    def repo_files
      return @repo_files if defined?(@repo_files)
      return @repo_files = [] unless bare_clone_path.exist?

      output = git("ls-tree", "-r", "--name-only", "HEAD")
      @repo_files = output.to_s.lines.map(&:strip).reject(&:blank?)
    end

    def git_show(rev)
      output = `git --git-dir #{bare_clone_path.to_s.shellescape} show #{rev.shellescape} 2>/dev/null`
      $?.success? ? output : nil
    end

    def git(*args)
      escaped = args.map { |arg| arg.to_s.shellescape }.join(" ")
      output = `git --git-dir #{bare_clone_path.to_s.shellescape} #{escaped} 2>/dev/null`
      $?.success? ? output : nil
    end

    def bare_clone_path
      @bare_clone_path ||= RepositoryBareClone.path_for(repository)
    end

    def preview_configured?
      @preview_configured ||= App::PreviewAvailability.configured?(repository)
    end

    # Deliberately does not read `parsed_config` (the local bare clone): this
    # recommendation is served from the web tier, which does not share the
    # worker's on-disk bare clone (see "Deploy target" in CLAUDE.md), so a
    # repo that has actually enabled visual review would otherwise never
    # resolve as already-configured and would keep recommending itself.
    # RepoVisualReviewPlan reads the same config over the GitHub API and is
    # the same resolver the Initial workflow uses to decide whether the
    # visual_review step runs at all, so "already onboarded" here matches
    # what actually happens on the next Job.
    def visual_review_enabled?
      @visual_review_enabled = RepoVisualReviewPlan.new(repository: repository, user: user).resolve.enabled? if @visual_review_enabled.nil?
      @visual_review_enabled
    end

    def preview_seed_configured?
      parsed_config&.preview&.seed.present?
    end

    def preview_seed_notes_present?
      parsed_config&.visual_review&.seed_notes.present?
    end

    def latest_preview_seedish_failure?
      env = repository.preview_environments.reorder(created_at: :desc, id: :desc).first
      return false unless env&.failed?

      env.error_message.to_s.match?(/seed|setup|reach|health|timeout|connect|login/i)
    end

    def browser_app?
      repo_files.any? do |path|
        path.in?(%w[package.json vite.config.ts vite.config.js next.config.js next.config.mjs]) ||
          path.start_with?("app/frontend/", "src/App.", "src/pages/", "pages/", "app/javascript/", "frontend/")
      end
    end

    def github_actions_workflow?
      repo_files.any? { |path| path.start_with?(".github/workflows/") && path.end_with?(".yml", ".yaml") }
    end

    def health_signals?
      parsed_config&.grade&.steps&.any? || repository.ci_health_healthy? || repository.grader_health_healthy?
    end

    def early_setup?
      repository.ci_health_unknown? || repository.grader_health_unknown? || github_actions_workflow? == false && parsed_config&.grade.blank?
    end

    def external_pr_signals?
      repository.jobs.where.not(external_pr_number: nil).exists?
    end


    def delivery_configured?
      parsed_config&.raw_delivery.present?
    end

    def delivery_shape?
      repository.fork? ||
        repo_files.any? { |path| path.match?(/\A(.github\/workflows\/)?(release|hotfix|promotion)[-_]/i) } ||
        %w[develop development release staging].include?(repository.default_branch.to_s)
    end
  end
end
