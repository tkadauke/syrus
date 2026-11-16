require "pathname"
require "set"

module Syrus
  # Locates built-in and externally installed plugins without depending on
  # Rails initialization. The built-in root has precedence when both roots
  # contain the same plugin name.
  class PluginRoots
    Problem = Data.define(:code, :path, :plugin_name, :message)

    attr_reader :built_in_root, :external_root, :problems

    def self.default
      new(application_root: Pathname.new(__dir__).join("../..").expand_path)
    end

    def initialize(application_root:, external_path: ENV["SYRUS_PLUGIN_PATH"])
      @built_in_root = Pathname.new(application_root).expand_path.join("plugins")
      @external_root = Pathname.new(external_path).expand_path unless external_path.to_s.strip.empty?
      @problems = []
      validate_external_root
      detect_duplicates
    end

    def roots
      [ built_in_root, valid_external_root ].compact
    end

    def plugin_directories
      seen = {}
      roots.flat_map do |root|
        child_directories(root).filter_map do |directory|
          name = directory.basename.to_s
          next if seen[name]

          seen[name] = true
          directory
        end
      end
    end

    def resolve(name)
      plugin_directories.find { |directory| directory.basename.to_s == name.to_s }
    end

    def built_in?(directory)
      contained_by?(directory, built_in_root)
    end

    def external?(directory)
      valid_external_root.present? && contained_by?(directory, valid_external_root)
    end

    def duplicate_names
      problems.select { |problem| problem.code == :duplicate }.map(&:plugin_name)
    end

    private

    def valid_external_root
      external_root if external_root&.directory?
    end

    def validate_external_root
      return unless external_root
      return if external_root.directory?

      code = external_root.exist? ? :not_directory : :missing
      @problems << Problem.new(
        code:,
        path: external_root,
        plugin_name: nil,
        message: "External plugin root #{external_root} #{code == :missing ? 'does not exist' : 'is not a directory'}"
      )
    end

    def detect_duplicates
      return unless valid_external_root && built_in_root.directory?

      built_in_names = child_directories(built_in_root).map { |directory| directory.basename.to_s }.to_set
      child_directories(valid_external_root).each do |directory|
        name = directory.basename.to_s
        next unless built_in_names.include?(name)

        @problems << Problem.new(
          code: :duplicate,
          path: directory,
          plugin_name: name,
          message: "Plugin #{name.inspect} exists in both plugin roots; using built-in #{built_in_root.join(name)} and skipping #{directory}"
        )
      end
    end

    def child_directories(root)
      return [] unless root.directory?

      root.children.select(&:directory?).sort_by { |directory| directory.basename.to_s }
    end

    def contained_by?(directory, root)
      path = Pathname.new(directory).expand_path
      path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
    end
  end
end
