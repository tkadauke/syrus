module Syrus
  # Reports and removes the durable data a plugin owns.
  #
  # Disable stops behavior; it deliberately does not touch data, so an operator
  # can turn a plugin off and back on without losing anything. That leaves a
  # gap: nothing ever removed a plugin's tables, so "deletable" was only true
  # of code. This is the other half.
  #
  # Ownership is derived from the same rule the namespace grader enforces --
  # a plugin owns the tables its models declare, and those names must carry its
  # prefix. Nothing here guesses from table names alone, so a core table can
  # never be dropped by purging a plugin.
  class PluginPurge
    Report = Data.define(:plugin_name, :tables, :row_counts) do
      def empty? = tables.empty?
      def total_rows = row_counts.values.sum
    end

    class UnknownPlugin < StandardError; end
    class PluginStillInstalled < StandardError; end

    def initialize(plugin_name)
      @plugin_name = plugin_name.to_s
    end

    # What a purge would remove. Safe to call at any time.
    def report
      Report.new(plugin_name: @plugin_name, tables: tables, row_counts: row_counts)
    end

    # Drops the plugin's tables. Refuses while the plugin is still registered:
    # purging code that is about to run again on the next boot would recreate
    # nothing and confuse everyone. Uninstall the gem first.
    def purge!(force: false)
      if !force && Syrus::PluginRegistry.registered_names.include?(@plugin_name)
        raise PluginStillInstalled,
              "#{@plugin_name} is still installed. Remove its gem from the Gemfile and restart before purging, or pass force: true."
      end

      dropped = []
      connection = ActiveRecord::Base.connection

      tables.each do |table|
        next unless connection.table_exists?(table)

        connection.drop_table(table)
        dropped << table
      end

      PluginRecord.where(name: @plugin_name).delete_all
      dropped
    end

    # Tables declared by models that live in the plugin's own directory. Reads
    # the migrations rather than the loaded constants when the plugin is gone,
    # so a purge still works after the gem has been removed.
    def tables
      @tables ||= (model_tables + migration_tables).uniq.select { |name| owned?(name) }.sort
    end

    def row_counts
      connection = ActiveRecord::Base.connection

      tables.to_h do |table|
        [ table, connection.table_exists?(table) ? connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i : 0 ]
      end
    end

    private

    def plugin_dir
      @plugin_dir ||= Rails.root.join("plugins", @plugin_name)
    end

    # A plugin owns a table only when the name carries its prefix. Belt and
    # braces against a model or migration in a plugin directory naming a core
    # table: a purge must never be able to drop `jobs`.
    def owned?(table)
      singular = @plugin_name.singularize
      table == @plugin_name || table.start_with?("#{@plugin_name}_") || table.start_with?("#{singular}_")
    end

    def model_tables
      return [] unless plugin_dir.directory?

      Dir.glob(plugin_dir.join("app/models/**/*.rb")).filter_map do |path|
        File.read(path)[/self\.table_name\s*=\s*["']([^"']+)["']/, 1]
      end
    end

    def migration_tables
      Dir.glob(plugin_dir.join("db/migrate/*.rb")).flat_map do |path|
        File.read(path).scan(/create_table\s*(?:\(\s*)?(?::([a-zA-Z_]\w*)|["']([^"']+)["'])/).flatten.compact
      end
    end
  end
end
