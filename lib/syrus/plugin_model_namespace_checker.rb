# frozen_string_literal: true

module Syrus
  class PluginModelNamespaceChecker
    Result = Data.define(:errors) do
      def success?
        errors.empty?
      end
    end

    ModelInfo = Data.define(:name, :table_name, :superclass_table_name, :abstract_class, :separate_database)

    def initialize(root: Rails.root, model_classes: nil)
      @root = Pathname.new(root)
      @model_classes = model_classes
    end

    def call
      load_plugin_models if @model_classes.nil?

      Result.new(errors: model_errors + migration_errors)
    end

    private

    attr_reader :root

    def plugin_root
      root.join("plugins")
    end

    def plugin_dirs
      return [] unless plugin_root.directory?

      plugin_root.children.select(&:directory?).sort_by(&:to_s)
    end

    def load_plugin_models
      plugin_dirs.each do |dir|
        Dir.glob(dir.join("app/models/**/*.rb")).sort.each do |path|
          require_dependency path
        end
      end
    end

    def model_errors
      plugin_model_infos.filter_map do |model|
        validate_model(model)
      end
    end

    def plugin_model_infos
      return @model_classes.map { |model| model_info(model) } if @model_classes

      ObjectSpace.each_object(Class).filter_map do |klass|
        next unless klass < ApplicationRecord
        next if klass.name.blank?

        source_path = Object.const_source_location(klass.name)&.first
        next if source_path.blank?
        next unless Pathname.new(source_path).expand_path.to_s.start_with?(plugin_root.expand_path.to_s)

        model_info(klass)
      end.sort_by(&:name)
    end

    def model_info(model)
      superclass_table_name =
        if model.respond_to?(:superclass) && model.superclass.respond_to?(:table_name)
          model.superclass.table_name
        end

      ModelInfo.new(
        name: model.name.to_s,
        table_name: model.table_name.to_s,
        superclass_table_name: superclass_table_name.to_s.presence,
        abstract_class: model.respond_to?(:abstract_class?) && model.abstract_class?,
        separate_database: model.respond_to?(:ancestors) && model.ancestors.any? { |ancestor| SEPARATE_DATABASE_BASES.include?(ancestor.name.to_s) }
      )
    end

    SEPARATE_DATABASE_BASES = %w[SearchRecord].freeze

    def validate_model(model)
      return "#{model.name} must be namespaced under its plugin module" unless model.name.include?("::")
      return if model.abstract_class
      # Models in a separate database (the FTS search database) are not part of
      # the primary schema this rule protects, and their table names are
      # already checked for collisions when plugins declare them through
      # :search_source.
      return if model.separate_database
      return if model.superclass_table_name.present? && model.superclass_table_name == model.table_name

      namespace = model.name.split("::").first.underscore
      return if permitted_table_name?(model.table_name, namespace)

      "#{model.name} uses table #{model.table_name.inspect}; plugin-owned model tables must start with #{namespace.inspect}, #{namespace + "_"} or #{namespace.singularize + "_"}"
    end

    def permitted_table_name?(table_name, namespace)
      table_name == namespace ||
        table_name.start_with?("#{namespace}_") ||
        table_name.start_with?("#{namespace.singularize}_")
    end

    def migration_errors
      plugin_dirs.flat_map do |dir|
        plugin_name = plugin_name_for(dir)
        paths = Dir.glob(dir.join("db/migrate/*.rb")).sort
        # The rule is about the schema the migrations arrive at, not every
        # intermediate name: a table created before the plugin was extracted
        # and renamed into the prefix later is fine.
        renamed = paths.flat_map { |path| renamed_table_names(path) }.to_h
        dropped = paths.flat_map { |path| dropped_table_names(path) }.to_set

        paths.flat_map do |path|
          create_table_names(path).filter_map do |table_name|
            final_name = renamed.fetch(table_name, table_name)
            # A table a later migration drops leaves nothing behind to name.
            next if dropped.include?(final_name)
            next if permitted_table_name?(final_name, plugin_name)

            "#{relative(path)} creates table #{table_name.inspect}; plugin migration tables must start with #{plugin_name.inspect}, #{plugin_name + "_"} or #{plugin_name.singularize + "_"}"
          end
        end
      end
    end

    def plugin_name_for(dir)
      gemspec = Dir.glob(dir.join("*.gemspec")).first
      return dir.basename.to_s unless gemspec

      File.read(gemspec)[/spec\.name\s*=\s*["']([^"']+)["']/, 1].presence || dir.basename.to_s
    end

    # [[old, new], ...] for every rename_table in this migration.
    def renamed_table_names(path)
      forward_source(File.read(path)).scan(/rename_table\s*(?:\(\s*)?:([a-zA-Z_]\w*)\s*,\s*:([a-zA-Z_]\w*)/)
    end

    def dropped_table_names(path)
      forward_source(File.read(path)).scan(/drop_table\s*(?:\(\s*)?:([a-zA-Z_]\w*)/).flatten
    end

    # Only the forward path: a `down` that recreates a table it is rolling
    # back is describing history, not the schema this plugin owns.
    def create_table_names(path)
      forward_source(File.read(path)).scan(/create_table\s*(?:\(\s*)?(?::([a-zA-Z_]\w*)|["']([^"']+)["'])/).flatten.compact
    end

    def forward_source(source)
      down = source.index(/^\s*def down\b/)
      down ? source[0...down] : source
    end

    def relative(path)
      Pathname.new(path).relative_path_from(root).to_s
    end
  end
end
