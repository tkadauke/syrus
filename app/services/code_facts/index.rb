module CodeFacts
  class Index
    DEFAULT_CHURN_WINDOWS = [ 30, 90 ].freeze

    FileFact = Data.define(
      :path,
      :language,
      :type,
      :line_count,
      :excluded,
      :exclusion_reasons,
      :last_modified_at,
      :last_modified_days_ago,
      :churn,
      :complexity
    )

    Result = Data.define(:repository_id, :sha, :generated_at, :churn_windows, :files, :rollup) do
      def included_files
        files.reject(&:excluded)
      end
    end

    def self.for_repository(repository:, sha:, user:, churn_windows: DEFAULT_CHURN_WINDOWS, now: Time.current, git: GitRunner.new)
      clone = RepositoryBareClone.new(repository, git: git)
      clone.sync!(user: user)

      new(
        repository: repository,
        git_path: clone.path,
        sha: sha,
        churn_windows: churn_windows,
        now: now,
        git: git
      ).call
    end

    def self.for_workspace(workspace_path:, sha: "HEAD", churn_windows: DEFAULT_CHURN_WINDOWS, now: Time.current, git: GitRunner.new)
      new(
        git_path: workspace_path,
        sha: sha,
        churn_windows: churn_windows,
        now: now,
        git: git
      ).call
    end

    def initialize(git_path:, sha:, repository: nil, churn_windows: DEFAULT_CHURN_WINDOWS, now: Time.current, git: GitRunner.new)
      @repository = repository
      @git_path = git_path
      @sha = sha
      @churn_windows = churn_windows.map(&:to_i).uniq.sort
      @now = now
      @git = git
    end

    def call
      file_entries = reader.file_entries_at(sha)
      facts = batch_facts
      files = file_entries.map { |entry| fact_for(entry, facts) }

      Result.new(
        repository_id: repository&.id,
        sha: sha,
        generated_at: now,
        churn_windows: churn_windows,
        files: files,
        rollup: rollup_for(files)
      )
    end

    private

    attr_reader :repository, :git_path, :sha, :churn_windows, :now, :git

    def fact_for(entry, facts)
      path = entry.path
      type = Classifier.type_for(path)
      last_modified_at = facts.fetch(:last_modified_times)[path]
      exclusion_reasons = exclusion.reasons_for(path)

      FileFact.new(
        path: path,
        language: Classifier.language_for(path),
        type: type,
        line_count: line_count(entry, facts.fetch(:line_counts)),
        excluded: exclusion_reasons.any?,
        exclusion_reasons: exclusion_reasons,
        last_modified_at: last_modified_at,
        last_modified_days_ago: days_ago(last_modified_at),
        churn: churn_windows.index_with { |days| churn_by_window.dig(days, path).to_i },
        complexity: Complexity.for(
          type: type,
          decision_count: facts.fetch(:decision_counts)[path],
          definition_count: facts.fetch(:definition_counts)[path]
        )
      )
    end

    def line_count(entry, line_counts)
      return 0 if entry.size == 0

      line_counts[entry.path]
    end

    def days_ago(time)
      return nil unless time

      ((now - time) / 1.day).floor
    end

    def rollup_for(files)
      included = files.reject(&:excluded)
      complexities = included.filter_map { |file| file.complexity["score"] }

      {
        "file_count" => included.size,
        "line_count" => included.sum { |file| file.line_count.to_i },
        "excluded_file_count" => files.count(&:excluded),
        "languages" => included.group_by(&:language).transform_values(&:size),
        "churn" => churn_windows.index_with { |days| included.sum { |file| file.churn[days].to_i } },
        "complexity" => {
          "max" => complexities.max,
          "average" => complexities.any? ? (complexities.sum.to_f / complexities.size).round(2) : nil
        }
      }
    end

    def exclusion
      @exclusion ||= Exclusion.new(generated_patterns: generated_patterns)
    end

    def reader
      @reader ||= GitReader.new(path: git_path, git: git)
    end

    def churn_by_window
      @churn_by_window ||= reader.churn_counts(sha, windows: churn_windows, now: now)
    end

    def batch_facts
      @batch_facts ||= {
        line_counts: reader.line_counts(sha),
        decision_counts: reader.complexity_counts(sha, Complexity::DECISION_GREP_PATTERN),
        definition_counts: reader.complexity_counts(sha, Complexity::DEFINITION_GREP_PATTERN),
        last_modified_times: reader.last_modified_times(sha)
      }
    end

    def generated_patterns
      @generated_patterns ||= begin
        config_contents = reader.file_contents(sha, config_paths)
        config_contents.flat_map do |config_path, contents|
          generated_patterns_for(config_path, contents)
        end
      end
    end

    def config_paths
      reader.files_at(sha).select do |path|
        path == SyrusYml::CONFIG_FILE || path.end_with?("/#{SyrusYml::CONFIG_FILE}")
      end
    end

    def generated_patterns_for(config_path, contents)
      package = File.dirname(config_path)
      package = "" if package == "."
      config = SyrusYml.new(contents, project_path: package.presence).parse
      return [] unless config.generated.is_a?(Array)

      config.generated.flat_map(&:generates).map do |pattern|
        package.present? ? "#{package}/#{pattern}" : pattern
      end
    rescue SyrusYml::ParseError
      []
    end
  end
end
