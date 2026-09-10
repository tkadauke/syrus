require "digest"
require "open3"
require "pathname"

class TargetGraph
  # Deterministic fingerprint set for one compiled target. The three values
  # map directly onto TargetHealthRecord's lookup tuple:
  #
  # - input: source files declared on the target and its dependencies, plus
  #   owning .syrus.yml files
  # - command: executable/config fields whose change invalidates stale health
  # - environment: toolchain and prepare dependency inputs available locally
  class Fingerprints
    Result = Data.define(:input_fingerprint, :command_fingerprint, :environment_fingerprint, :metadata) do
      def to_h
        {
          "input_fingerprint" => input_fingerprint,
          "command_fingerprint" => command_fingerprint,
          "environment_fingerprint" => environment_fingerprint,
          "metadata" => metadata
        }
      end
    end

    TOOLCHAIN_FILES = %w[
      .ruby-version
      .tool-versions
      Gemfile
      Gemfile.lock
      package.json
      package-lock.json
      pnpm-lock.yaml
      yarn.lock
      bun.lockb
      go.mod
      go.sum
      Cargo.toml
      Cargo.lock
      pyproject.toml
      poetry.lock
      uv.lock
      requirements.txt
    ].freeze

    def self.for_target(workspace_path:, graph:, label:)
      new(workspace_path: workspace_path, graph: graph).for_target(label)
    end

    def initialize(workspace_path:, graph:)
      @workspace_path = Pathname.new(workspace_path)
      @graph = graph
    end

    def for_target(label)
      target = graph.target(label)
      raise TargetGraph::ValidationError, "unknown target #{label}" unless target

      dependencies = graph.dependency_closure_for(target.label)
        .filter_map { |dependency_label| graph.target(dependency_label) }
      relevant_targets = [ target, *dependencies ]
      prepare_targets = dependencies.select { |dependency| dependency.kind == "prepare" && dependency.executable? }

      Result.new(
        input_fingerprint: digest(input_payload(target, relevant_targets)),
        command_fingerprint: digest(command_payload(target, dependencies)),
        environment_fingerprint: digest(environment_payload(target, prepare_targets)),
        metadata: {
          "source_file_count" => source_file_entries(relevant_targets).size,
          "config_file_count" => config_file_entries(relevant_targets).size,
          "dependency_labels" => dependencies.map { |dependency| dependency.label.to_s },
          "prepare_target_labels" => prepare_targets.map { |dependency| dependency.label.to_s }
        }
      )
    end

    private

    attr_reader :workspace_path, :graph

    def input_payload(target, relevant_targets)
      {
        "target_label" => target.label.to_s,
        "source_scopes" => relevant_targets.to_h { |entry| [ entry.label.to_s, sorted_strings(entry.source_scope) ] },
        "source_files" => source_file_entries(relevant_targets),
        "config_files" => config_file_entries(relevant_targets)
      }
    end

    def command_payload(target, dependencies)
      {
        "target" => target_config_payload(target),
        "dependencies" => dependencies.map { |dependency| target_config_payload(dependency) }
      }
    end

    def environment_payload(target, prepare_targets)
      {
        "target_label" => target.label.to_s,
        "ruby" => RUBY_VERSION,
        "ruby_platform" => RUBY_PLATFORM,
        "bundler_version" => bundler_version,
        "env" => {
          "BUNDLE_WITHOUT" => ENV["BUNDLE_WITHOUT"].to_s,
          "RAILS_ENV" => ENV["RAILS_ENV"].to_s,
          "NODE_ENV" => ENV["NODE_ENV"].to_s
        },
        "prepare_targets" => prepare_targets.map { |prepare| target_config_payload(prepare) },
        "toolchain_files" => toolchain_file_entries(target)
      }
    end

    def target_config_payload(target)
      {
        "label" => target.label.to_s,
        "kind" => target.kind,
        "project_id" => target.project_id,
        "source_scope" => sorted_strings(target.source_scope),
        "command" => target.command.to_s,
        "dependencies" => sorted_strings(target.dependencies.map(&:to_s)),
        "phases" => sorted_strings(target.phases),
        "required" => !!target.required,
        "timeout_minutes" => target.timeout_minutes.to_i,
        "owner_config_path" => target.owner_config_path.to_s,
        "metadata" => normalize_hash(target.metadata)
      }
    end

    def source_file_entries(relevant_targets)
      patterns = relevant_targets.flat_map(&:source_scope).map(&:to_s).reject(&:empty?).uniq
      paths = if patterns.empty?
        repository_files
      else
        repository_files.select { |path| patterns.any? { |pattern| File.fnmatch(pattern, path, File::FNM_DOTMATCH) } }
      end

      file_entries(paths)
    end

    def config_file_entries(relevant_targets)
      paths = relevant_targets.filter_map { |target| target.owner_config_path.to_s.presence }.uniq
      file_entries(paths)
    end

    def toolchain_file_entries(target)
      project_path = graph.project(target.project_id)&.path.to_s.presence
      prefixes = [ "", project_path ].compact.uniq
      paths = prefixes.flat_map do |prefix|
        TOOLCHAIN_FILES.map { |file| prefix.present? ? "#{prefix}/#{file}" : file }
      end

      file_entries(paths.uniq)
    end

    def file_entries(paths)
      paths.sort.filter_map do |relative_path|
        absolute_path = workspace_path.join(relative_path)
        next unless absolute_path.file?

        {
          "path" => relative_path,
          "sha256" => Digest::SHA256.file(absolute_path).hexdigest,
          "bytes" => absolute_path.size
        }
      end
    end

    def repository_files
      @repository_files ||= begin
        stdout, _stderr, status = Open3.capture3("git", "ls-files", chdir: workspace_path.to_s)
        if status.success?
          stdout.lines.map(&:strip).reject(&:empty?)
        else
          Dir.glob("**/*", File::FNM_DOTMATCH, base: workspace_path.to_s)
            .reject { |path| path == "." || path.start_with?(".git/") || path.start_with?(".syrus/") }
            .select { |path| workspace_path.join(path).file? }
        end
      end
    end

    def bundler_version
      return Bundler::VERSION if defined?(Bundler::VERSION)

      nil
    end

    def sorted_strings(values)
      Array(values).map(&:to_s).sort
    end

    def normalize_hash(value)
      value.to_h.transform_keys(&:to_s).sort.to_h.transform_values do |entry|
        case entry
        when Hash
          normalize_hash(entry)
        when Array
          entry.map { |item| item.is_a?(Hash) ? normalize_hash(item) : item }
        else
          entry
        end
      end
    end

    def digest(payload)
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end
  end
end
