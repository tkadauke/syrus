module SdlcPipeline
  class Filter
    include Filters::BaseFilter

    def self.subject = SmartFolders::SUBJECT

    def self.build_tree_from_url_params(_params)
      nil
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: self.class.subject)
    end
  end
end
