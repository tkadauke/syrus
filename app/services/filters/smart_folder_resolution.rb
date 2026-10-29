module Filters
  # Canonical request contract for a FilterBar backed by SmartFolders.
  # The returned filter is both the editable response AST and the filter that
  # callers must apply to their result scope.
  class SmartFolderResolution
    PRESET_FIELD = "smart_folder_preset"

    attr_reader :active_smart_folder, :filter

    def self.call(filter_class:, subject:, params:, active_smart_folder:, user: nil, filter_options: {})
      new(filter_class:, subject:, params:, active_smart_folder:, user:, filter_options:).call
    end

    def self.preset_tree(key)
      { "and" => [ { "field" => PRESET_FIELD, "op" => "is", "value" => key.to_s } ] }
    end

    def initialize(filter_class:, subject:, params:, active_smart_folder:, user: nil, filter_options: {})
      @filter_class = filter_class
      @subject = subject.to_s
      @params = params
      @active_smart_folder = active_smart_folder
      @user = user
      @filter_options = filter_options
    end

    def call
      @filter = if q_present?
        filter_class.from_tree(explicit_q_tree, user: user)
      elsif legacy_filter_active?
        filter_class.from_params(params, user: user, **filter_options)
      elsif preset_definition
        filter_class.from_tree(self.class.preset_tree(active_smart_folder.builtin_key), user: user)
      else
        filter_class.from_params(params, smart_folder: active_smart_folder, user: user, **filter_options)
      end
      self
    end

    def active_smart_folder_id
      active_smart_folder&.id
    end

    def navigation
      { active_smart_folder_id: active_smart_folder_id }
    end

    private

    attr_reader :filter_class, :subject, :params, :user, :filter_options

    def q_present?
      params.key?(Filters::QueryParam::PARAM_NAME) || params.key?(Filters::QueryParam::PARAM_NAME.to_s)
    end

    def explicit_q_tree
      Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME] || params[Filters::QueryParam::PARAM_NAME.to_s]) ||
        Filters::Ast.serialize(Filters::Ast::EMPTY)
    end

    def legacy_filter_active?
      if filter_class.respond_to?(:legacy_filter_active?)
        return filter_class.legacy_filter_active?(params, user: user, **filter_options)
      end

      filter_class.from_params(params, user: user, **filter_options).active?
    end

    def preset_definition
      return unless active_smart_folder&.builtin? && active_smart_folder.builtin_key.present?

      SmartFolder.builtins_for_subject(subject).find do |definition|
        SmartFolder.filter_bar_preset?(definition) && definition.fetch(:key).to_s == active_smart_folder.builtin_key
      end
    end
  end
end
