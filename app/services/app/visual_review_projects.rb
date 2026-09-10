require "syrus/plugin/preview_provider"

module App
  # Resolves workflow-local preview projects for a visual_review Run from the
  # actual diff under review. This deliberately reads the checked-out workflow
  # workspace instead of the repository bare clone so review loops follow the
  # implement/respond step's scoped diff, including retry and feedback runs.
  class VisualReviewProjects
    Choice = Data.define(:id, :label, :path, :owner_config_path, :seed_notes, :when_files_changed) do
      def to_h
        {
          "id" => id,
          "label" => label,
          "path" => path,
          "owner_config_path" => owner_config_path,
          "seed_notes" => seed_notes,
          "when_files_changed" => when_files_changed
        }
      end
    end

    Result = Data.define(:choices, :unavailable_reason) do
      def available? = choices.any?
      def single? = choices.one?
      def choice(id) = choices.find { |candidate| candidate.id == id.to_s }
      def to_a = choices.map(&:to_h)

      def seed_notes
        choices.filter_map(&:seed_notes).map(&:presence).compact.uniq.join("\n\n")
      end

      def when_files_changed
        choices.flat_map { |choice| Array(choice.when_files_changed) }.uniq
      end
    end

    def self.call(workspace_path:, changed_files:)
      new(workspace_path, changed_files: changed_files).call
    end

    def initialize(workspace_path, changed_files:)
      @workspace_path = Pathname.new(workspace_path)
      @changed_files = Array(changed_files).map(&:to_s)
    end

    def call
      preview_projects = project_choices
      return Result.new(choices: [], unavailable_reason: "no_preview_configured") if preview_projects.empty?

      affected = preview_projects.select { |project| affected_project?(project) }
      return Result.new(choices: [], unavailable_reason: "no_affected_preview_project") if affected.empty?

      enabled = affected.select { |project| visual_review_enabled?(project.visual_review) }
      return Result.new(choices: [], unavailable_reason: "no_affected_visual_review_project") if enabled.empty?

      Result.new(choices: enabled.map { |project| choice_for(project) }, unavailable_reason: nil)
    rescue StandardError => e
      Rails.logger.warn("[App::VisualReviewProjects] unavailable for #{@workspace_path}: #{e.class}: #{e.message}")
      Result.new(choices: [], unavailable_reason: "visual_review_project_resolution_failed")
    end

    private

    attr_reader :workspace_path, :changed_files

    def graph
      @graph ||= TargetGraph::Compiler.compile(workspace_path)
    end

    def project_choices
      graph_projects = graph.projects.values.select(&:preview)
      return graph_projects if graph_projects.any?

      return [] unless Syrus::Plugin::PreviewProvider.for_repo(workspace_path)

      [
        TargetGraph::Project.new(
          id: TargetGraph::ROOT_PROJECT_ID,
          label: "Repository",
          path: "",
          owner_config_path: nil
        )
      ]
    end

    def affected_project?(project)
      return true if changed_files.empty?
      return true if project.path.blank?

      changed_files.any? { |file| file == project.path || file.start_with?("#{project.path}/") }
    end

    def visual_review_enabled?(config)
      config&.enabled.nil? ? Feature.visual_review_enabled? : config.enabled
    end

    def choice_for(project)
      Choice.new(
        id: project.id,
        label: project.label,
        path: project.path,
        owner_config_path: project.owner_config_path,
        seed_notes: project.visual_review&.seed_notes,
        when_files_changed: scoped_when_files_changed(project)
      )
    end

    def scoped_when_files_changed(project)
      patterns = Array(project.visual_review&.when_files_changed).map(&:to_s).map(&:strip).reject(&:empty?)
      return nil if patterns.empty?
      return patterns if project.path.blank?

      patterns.map { |pattern| "#{project.path}/#{pattern}" }
    end
  end
end
