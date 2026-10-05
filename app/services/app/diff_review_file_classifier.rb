module App
  class DiffReviewFileClassifier
    Match = Data.define(:generated, :generated_reason, :generated_source)
    Pattern = Data.define(:glob, :reason, :source)

    CORE_GENERATED_PATTERNS = [
      Pattern.new("**/__generated__/**", "generated path", "core"),
      Pattern.new("**/generated/**", "generated path", "core"),
      Pattern.new("*.generated.*", "generated file", "core"),
      Pattern.new("**/*.generated.*", "generated file", "core"),
      Pattern.new("**/*.pb.go", "generated file", "core"),
      Pattern.new("**/*.pb.rb", "generated file", "core"),
      Pattern.new("**/*.pb.py", "generated file", "core"),
      Pattern.new("**/*.g.dart", "generated file", "core"),
      Pattern.new("**/*.gen.ts", "generated file", "core"),
      Pattern.new("**/*.gen.tsx", "generated file", "core"),
      Pattern.new("**/node_modules/**", "vendored dependency", "core")
    ].freeze

    CORE_LOCKFILE_PATTERNS = %w[
      Gemfile.lock
      package-lock.json
      npm-shrinkwrap.json
      yarn.lock
      pnpm-lock.yaml
      bun.lock
      bun.lockb
      poetry.lock
      Pipfile.lock
      uv.lock
      requirements.lock
      go.sum
      Cargo.lock
      composer.lock
    ].freeze

    def self.for(job:, user:)
      new(repository: job.repository, user: user || job.user)
    end

    def initialize(repository:, user:)
      @repository = repository
      @user = user
    end

    def classify(path)
      normalized_path = normalize_path(path)
      return Match.new(false, nil, nil) if normalized_path.blank?

      matching_pattern = patterns.find { |pattern| glob_matches?(pattern.glob, normalized_path) }
      return Match.new(true, matching_pattern.reason, matching_pattern.source) if matching_pattern

      Match.new(false, nil, nil)
    end

    private

    attr_reader :repository, :user

    def patterns
      @patterns ||= syrus_yml_generated_patterns + diff_review_file_pattern_provider_patterns + plugin_lockfile_patterns + core_patterns
    end

    def syrus_yml_generated_patterns
      config = RepoDefaultBranchSyrusYml.new(repository: repository, user: user).resolve.config
      Array(config&.generated).flat_map do |entry|
        Array(entry.generates).map { |glob| Pattern.new(glob, "configured generated output", ".syrus.yml") }
      end
    end

    def diff_review_file_pattern_provider_patterns
      Syrus::PluginRegistry.providers_for(:diff_review_file_pattern_provider).flat_map do |provider|
        Array(provider.diff_review_file_patterns).filter_map do |entry|
          attrs = entry.respond_to?(:to_h) ? entry.to_h.with_indifferent_access : {}
          glob = attrs[:glob].to_s.strip
          next if glob.blank?

          Pattern.new(glob, attrs[:reason].presence || "generated file", attrs[:source].presence || provider_source(provider))
        end
      end
    end

    def plugin_lockfile_patterns
      Syrus::PluginRegistry.providers_for(:dependency_audit_command).flat_map do |provider|
        next [] unless provider.respond_to?(:lockfiles)

        Array(provider.lockfiles).map { |glob| Pattern.new(glob, "lockfile", "dependency_audit") }
      end
    end

    def core_patterns
      CORE_GENERATED_PATTERNS + CORE_LOCKFILE_PATTERNS.map { |glob| Pattern.new(glob, "lockfile", "core") }
    end

    def glob_matches?(glob, path)
      pattern = normalize_path(glob)
      return false if pattern.blank?

      flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
      File.fnmatch?(pattern, path, flags) ||
        File.fnmatch?(pattern, File.basename(path), flags) ||
        File.fnmatch?("**/#{pattern}", path, flags)
    end

    def normalize_path(path)
      path.to_s.delete_prefix("./").delete_prefix("/")
    end

    def provider_source(provider)
      provider.respond_to?(:name) ? provider.name.presence || "plugin" : provider.class.name.presence || "plugin"
    end
  end
end
