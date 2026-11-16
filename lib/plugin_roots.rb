# frozen_string_literal: true

require "pathname"

# The filesystem boundary for bundled and externally installed plugins.
# This file deliberately has no Rails dependency so config/application.rb and
# command-line tooling can load it before Rails initializers run.
class PluginRoots
  attr_reader :built_in_root, :external_root, :duplicates

  def self.default
    @default ||= new(application_root: Pathname.new(__dir__).join("..").expand_path)
  end

  def self.reset_default! = (@default = nil)

  def initialize(application_root:, external_path: ENV["SYRUS_PLUGIN_PATH"])
    @built_in_root = Pathname.new(application_root).join("plugins").expand_path
    @external_root = external_path.to_s.empty? ? nil : Pathname.new(external_path).expand_path
    @duplicates = []
  end

  def roots
    [ built_in_root, valid_external_root ].compact
  end

  def plugin_directories
    @duplicates = []
    seen = {}

    roots.flat_map do |root|
      next [] unless root.directory?

      root.children.select(&:directory?).sort_by { |path| path.basename.to_s }.filter_map do |directory|
        name = directory.basename.to_s
        if seen.key?(name)
          @duplicates << Duplicate.new(name:, built_in: seen.fetch(name), skipped: directory)
          nil
        else
          seen[name] = directory
        end
      end
    end
  end

  def resolve(name)
    plugin_directories.find { |directory| directory.basename.to_s == name.to_s }
  end

  def migration_directories
    plugin_directories.map { |directory| directory.join("db/migrate") }.select(&:directory?)
  end

  def built_in?(directory)
    within?(directory, built_in_root)
  end

  def external?(directory)
    external_root && within?(directory, external_root)
  end

  Duplicate = Data.define(:name, :built_in, :skipped) do
    def message
      "plugin #{name.inspect} exists in both roots; using #{built_in} and skipping #{skipped}"
    end
  end

  private

  def valid_external_root
    external_root if external_root&.directory?
  end

  def within?(directory, root)
    path = Pathname.new(directory).expand_path
    path == root || path.to_s.start_with?("#{root}#{File::SEPARATOR}")
  end
end
