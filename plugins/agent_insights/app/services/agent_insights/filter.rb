module AgentInsights
  class Filter
    include Filters::BaseFilter

    STATES = %w[pending accepted dismissed retired all].freeze

    def self.schema(user: nil)
      Filters::Schema.for(subject: AgentInsights::SmartFolders::SUBJECT, user: user)
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: AgentInsights::SmartFolders::SUBJECT)
    end

    def self.build_tree_from_url_params(params)
      state = params[:state].to_s
      return nil unless STATES.include?(state) && state != "all"

      { "and" => [ chip("state", "is", state) ] }
    end
    private_class_method :build_tree_from_url_params
  end
end
