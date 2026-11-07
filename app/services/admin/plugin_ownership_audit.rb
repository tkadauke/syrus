require "yaml"

module Admin
  class PluginOwnershipAudit
    Ownership = Data.define(:plugin, :path, :categories, :vocabulary, :quarantine)
    Finding = Data.define(:plugin, :path, :actual, :allowed) do
      def message
        trend = actual - allowed
        "#{path}: #{plugin} vocabulary inventory actual #{actual}, baseline #{allowed}, trend #{trend.positive? ? '+' : ''}#{trend}"
      end
    end

    CORE_ROOTS = %w[app lib config bin website].freeze
    SOURCE_EXTENSIONS = %w[.rb .rake .erb .ts .tsx .js .jsx .yml .yaml .md].freeze
    MANIFEST_PATH = "config/plugin_ownership.yml"

    def initialize(root: Rails.root, ownerships: nil)
      @root = Pathname.new(root)
      @ownerships = ownerships
    end

    def ownerships
      @ownerships ||= plugin_dirs.filter_map { |dir| ownership_for(dir) }
    end

    def findings
      ownerships.flat_map do |ownership|
        actual = inventory_for(ownership)
        paths = actual.keys | ownership.quarantine.keys
        paths.filter_map do |path|
          count = actual.fetch(path, 0)
          allowed = ownership.quarantine.fetch(path, 0)
          next if count == allowed

          Finding.new(plugin: ownership.plugin, path:, actual: count, allowed:)
        end
      end
    end

    def inventory_for(ownership)
      matcher = Regexp.union(ownership.vocabulary.map { |term| /#{Regexp.escape(term)}/i })
      core_files.each_with_object({}) do |path, inventory|
        count = File.read(path).scan(matcher).size
        inventory[relative(path)] = count if count.positive?
      end
    end

    private

    attr_reader :root

    def plugin_dirs
      plugins = root.join("plugins")
      return [] unless plugins.directory?

      plugins.children.select(&:directory?)
    end

    def ownership_for(dir)
      path = dir.join(MANIFEST_PATH)
      return unless path.file?

      data = YAML.safe_load_file(path)
      categories = data.fetch("ownership")
      Ownership.new(
        plugin: data.fetch("plugin"),
        path: relative(path),
        categories:,
        vocabulary: Array(categories.fetch("vocabulary")),
        quarantine: data.fetch("compatibility_quarantine", {}).transform_values { |count| Integer(count) }
      )
    end

    def core_files
      CORE_ROOTS.flat_map do |directory|
        absolute = root.join(directory)
        next [] unless absolute.exist?

        Dir.glob(absolute.join("**/*")).filter_map do |candidate|
          path = Pathname.new(candidate)
          path if path.file? && SOURCE_EXTENSIONS.include?(path.extname) && tracked?(path)
        end
      end
    end

    def tracked?(path)
      return true if tracked_paths.nil?

      tracked_paths.include?(relative(path))
    end

    def tracked_paths
      return @tracked_paths if defined?(@tracked_paths)

      @tracked_paths = GitRunner.new.run("ls-files", "-z", chdir: root.to_s).split("\0").to_set
    rescue StandardError
      @tracked_paths = nil
    end

    def relative(path)
      Pathname.new(path).relative_path_from(root).to_s
    end
  end
end
