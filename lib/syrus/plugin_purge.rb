require "yaml"

module Syrus
  # Reports and removes the durable data a plugin owns.
  #
  # Disable stops behavior; it deliberately does not touch data, so an operator
  # can turn a plugin off and back on without losing anything. That leaves a
  # gap: nothing ever removed a plugin's tables, so "deletable" was only true
  # of code. This is the other half.
  #
  # Table ownership is derived from the same rule the namespace grader
  # enforces: a plugin owns the tables its models declare, and those names must
  # carry its prefix. Shared-table cleanup is allowed only when the ownership
  # manifest explicitly declares the rows and columns to remove.
  class PluginPurge
    # `other_data` lists what purge contributors hold for the plugin outside
    # the database, such as a container-backed plugin's volumes.
    InlineField = Data.define(:table, :column)

    Report = Data.define(:plugin_name, :tables, :row_counts, :inline_fields, :inline_row_counts, :other_data) do
      def initialize(plugin_name:, tables:, row_counts:, inline_fields: [], inline_row_counts: {}, other_data: [])
        super
      end

      def empty? = tables.empty? && inline_fields.empty? && other_data.empty?
      def total_rows = row_counts.values.sum + inline_row_counts.values.sum
    end

    UNAVAILABLE_LINE = "a purge contributor could not be loaded; its data may remain (see plugin health)"

    class UnknownPlugin < StandardError; end
    class PluginStillInstalled < StandardError; end

    def initialize(plugin_name)
      @plugin_name = plugin_name.to_s
    end

    # What a purge would remove. Safe to call at any time.
    def report
      Report.new(
        plugin_name: @plugin_name,
        tables: tables,
        row_counts: row_counts,
        inline_fields: inline_fields,
        inline_row_counts: inline_row_counts,
        other_data: other_data
      )
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

      purge_inline_rows(connection)
      inline_fields.each do |field|
        next unless connection.table_exists?(field.table) && connection.column_exists?(field.table, field.column)

        connection.remove_column(field.table, field.column)
        dropped << "#{field.table}.#{field.column}"
      end

      tables.each do |table|
        next unless connection.table_exists?(table)

        connection.drop_table(table)
        dropped << table
      end

      # Every contributor purges; one that fails is reported in the result
      # instead of silently skipping its data, and the others still run.
      removed = contributors.flat_map do |contributor|
        next [ UNAVAILABLE_LINE ] if Syrus::Plugin::DataPolicy.unavailable?(contributor)

        result = Syrus::PluginInvocation.call(
          extension_point: :purge_contributor, provider: contributor, operation: :purge, on_decline: []
        ) { Array(contributor.purge!(@plugin_name)) }
        if result.is_a?(Syrus::PluginInvocation::Failed)
          next [ "#{contributor}: purge failed (#{result.exception_class}: #{result.message})" ]
        end
        Syrus::PluginInvocation.value(result)
      end

      PluginRecord.where(name: @plugin_name).delete_all
      dropped + removed
    end

    # What enabled purge contributors hold for this plugin. A contributor that
    # cannot answer says so rather than hiding data from the report.
    def other_data
      contributors.flat_map do |contributor|
        next [ UNAVAILABLE_LINE ] if Syrus::Plugin::DataPolicy.unavailable?(contributor)

        result = Syrus::PluginInvocation.call(
          extension_point: :purge_contributor, provider: contributor, operation: :purge_report,
          on_decline: []
        ) { Array(contributor.purge_report(@plugin_name)) }
        if result.is_a?(Syrus::PluginInvocation::Failed)
          next [ "#{contributor}: could not report (#{result.exception_class}: #{result.message})" ]
        end
        Syrus::PluginInvocation.value(result)
      end
    end

    def contributors
      Syrus::Plugin::DataPolicy.purge_contributors.map do |provider|
        provider.is_a?(String) ? provider.constantize : provider
      end
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

    def inline_fields
      @inline_fields ||= inline_field_configuration.flat_map do |table, configuration|
        Array(configuration.fetch("drop_columns", [])).map do |column|
          InlineField.new(table: table.to_s, column: column.to_s)
        end
      end
    end

    def inline_row_counts
      connection = ActiveRecord::Base.connection

      inline_field_configuration.each_with_object({}) do |(table, configuration), counts|
        column = configuration["delete_rows_where_present"]
        next if column.blank? || !connection.table_exists?(table) || !connection.column_exists?(table, column)

        quoted_table = connection.quote_table_name(table)
        quoted_column = connection.quote_column_name(column)
        counts[table.to_s] = connection.select_value(
          "SELECT COUNT(*) FROM #{quoted_table} WHERE #{quoted_column} IS NOT NULL"
        ).to_i
      end
    end

    private

    def plugin_dir
      @plugin_dir ||= Syrus::PluginRoots.default.resolve(@plugin_name) || Syrus::PluginRoots.default.built_in_root.join(@plugin_name)
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

    def inline_field_configuration
      @inline_field_configuration ||= begin
        path = plugin_dir.join("config/plugin_ownership.yml")
        if path.file?
          data = YAML.safe_load_file(path)
          fields = data.dig("ownership", "inline_fields")
          fields.is_a?(Hash) ? fields : {}
        else
          {}
        end
      end
    end

    def purge_inline_rows(connection)
      inline_field_configuration.each do |table, configuration|
        column = configuration["delete_rows_where_present"]
        next if column.blank? || !connection.table_exists?(table) || !connection.column_exists?(table, column)

        quoted_table = connection.quote_table_name(table)
        quoted_column = connection.quote_column_name(column)
        connection.delete("DELETE FROM #{quoted_table} WHERE #{quoted_column} IS NOT NULL")
      end
    end
  end
end
