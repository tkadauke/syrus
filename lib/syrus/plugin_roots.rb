require "pathname"

module Syrus
  # Locates built-in, hand-placed, and synced plugins without depending on
  # Rails initialization. Precedence follows that order when roots contain
  # the same plugin name.
  class PluginRoots
    Problem = Data.define(:code, :path, :plugin_name, :message)

    attr_reader :built_in_root, :external_root, :synced_root, :problems

    def self.default
      new(application_root: Pathname.new(__dir__).join("../..").expand_path)
    end

    def initialize(application_root:, external_path: ENV["SYRUS_PLUGIN_PATH"], synced_path: default_synced_path)
      @built_in_root = Pathname.new(application_root).expand_path.join("plugins")
      @external_root = Pathname.new(external_path).expand_path unless external_path.to_s.strip.empty?
      @synced_root = Pathname.new(synced_path).expand_path unless synced_path.to_s.strip.empty?
      @problems = []
      validate_root(external_root, "External")
      validate_root(synced_root, "Synced")
      detect_duplicates
    end

    def roots
      [ built_in_root, valid_root(external_root), valid_root(synced_root) ].compact
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
      requested_name = name.to_s
      plugin_directories.find do |directory|
        directory.basename.to_s == requested_name || declared_plugin_name(directory) == requested_name
      end
    end

    def built_in?(directory)
      contained_by?(directory, built_in_root)
    end

    def external?(directory)
      [ external_root, synced_root ].compact.any? do |root|
        valid_root(root) && contained_by?(directory, root)
      end
    end

    def duplicate_names
      problems.select { |problem| problem.code == :duplicate }.map(&:plugin_name)
    end

    private

    def default_synced_path
      data_root = ENV.fetch("SYRUS_DATA_ROOT", File.expand_path("~/.syrus"))
      path = File.join(data_root, "plugin-sync/current")
      path if ENV["SYRUS_PLUGIN_SYNC_ENABLED"] == "1" || File.directory?(path)
    end

    def valid_root(root)
      root if root&.directory?
    end

    def validate_root(root, label)
      return unless root
      return if root.directory?

      code = root.exist? ? :not_directory : :missing
      @problems << Problem.new(
        code:,
        path: root,
        plugin_name: nil,
        message: "#{label} plugin root #{root} #{code == :missing ? 'does not exist' : 'is not a directory'}"
      )
    end

    def detect_duplicates
      seen = {}
      roots.each do |root|
        child_directories(root).each do |directory|
          name = directory.basename.to_s
          if (winner = seen[name])
            @problems << Problem.new(code: :duplicate, path: directory, plugin_name: name,
              message: "Plugin #{name.inspect} exists in both plugin roots; using #{winner} and skipping #{directory}")
          else
            seen[name] = directory
          end
        end
      end
    end

    def child_directories(root)
      return [] unless root.directory?

      root.children.select(&:directory?).sort_by { |directory| directory.basename.to_s }
    end

    # The registry identity comes from `syrus_plugin`, not from the installer
    # directory or gem name. Read only the declaration here: evaluating an
    # entry file just to locate its app/docs/migrations would run plugin code.
    def declared_plugin_name(directory)
      directory.glob("lib/*.rb").sort.each do |entry_file|
        match = entry_file.read.match(/\bsyrus_plugin\s+["']([^"']+)["']/)
        return match[1] if match
      rescue SystemCallError
        next
      end
      nil
    end

    def contained_by?(directory, root)
      path = Pathname.new(directory).expand_path
      path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
    end
  end
end
