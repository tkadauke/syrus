# frozen_string_literal: true

module Syrus
  class PluginModelNamespaceChecker
    Result = Data.define(:errors) do
      def success?
        errors.empty?
      end
    end

    ModelInfo = Data.define(:name, :table_name, :superclass_table_name, :abstract_class)

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
        abstract_class: model.respond_to?(:abstract_class?) && model.abstract_class?
      )
    end

    def validate_model(model)
      return "#{model.name} must be namespaced under its plugin module" unless model.name.include?("::")
      return if model.abstract_class
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

        Dir.glob(dir.join("db/migrate/*.rb")).sort.flat_map do |path|
          create_table_names(path).filter_map do |table_name|
            next if permitted_table_name?(table_name, plugin_name)

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

    def create_table_names(path)
      File.read(path).scan(/create_table\s*(?:\(\s*)?(?::([a-zA-Z_]\w*)|["']([^"']+)["'])/).flatten.compact
    end

    def relative(path)
      Pathname.new(path).relative_path_from(root).to_s
    end
  end
end
