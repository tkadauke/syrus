module Filters
  # Canonical request contract for a FilterBar backed by SmartFolders.
  # The returned filter is both the editable response AST and the filter that
  # callers must apply to their result scope.
  class SmartFolderResolution
    PRESET_FIELD = "smart_folder_preset"

    attr_reader :active_smart_folder, :filter

    def self.call(filter_class:, subject:, params:, active_smart_folder:, user: nil)
      new(filter_class:, subject:, params:, active_smart_folder:, user:).call
    end

    def self.preset_tree(key)
      { "and" => [ { "field" => PRESET_FIELD, "op" => "is", "value" => key.to_s } ] }
    end

    def initialize(filter_class:, subject:, params:, active_smart_folder:, user: nil)
      @filter_class = filter_class
      @subject = subject.to_s
      @params = params
      @active_smart_folder = active_smart_folder
      @user = user
    end

    def call
      @filter = if q_present?
        filter_class.from_tree(explicit_q_tree, user: user)
      elsif legacy_filter_active?
        filter_class.from_params(params, user: user)
      elsif active_smart_folder&.builtin? && active_smart_folder.builtin_key.present?
        filter_class.from_tree(self.class.preset_tree(active_smart_folder.builtin_key), user: user)
      else
        filter_class.from_params(params, smart_folder: active_smart_folder, user: user)
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

    attr_reader :filter_class, :subject, :params, :user

    def q_present?
      params.key?(Filters::QueryParam::PARAM_NAME) || params.key?(Filters::QueryParam::PARAM_NAME.to_s)
    end

    def explicit_q_tree
      Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME] || params[Filters::QueryParam::PARAM_NAME.to_s]) ||
        Filters::Ast.serialize(Filters::Ast::EMPTY)
    end

    def legacy_filter_active?
      filter_class.from_params(params, user: user).active?
    end
  end
end
