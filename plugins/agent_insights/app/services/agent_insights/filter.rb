module AgentInsights
  class Filter
    include Filters::BaseFilter

    def self.subject
      AgentInsights::SmartFolders::SUBJECT
    end

    def self.schema
      Filters::Schema.for(subject: subject)
    end

    def self.build_tree_from_url_params(params)
      state = params[:state].to_s.presence
      return nil if state.blank? || state == "all"

      { "and" => [ chip("state", "is", state) ] }
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: self.class.subject)
    end
  end
end
