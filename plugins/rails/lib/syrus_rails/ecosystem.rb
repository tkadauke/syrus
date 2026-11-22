module SyrusRails
  class Ecosystem
    class << self
      def key = :rails
      def display_name = "Rails"

      def prompt_context(context)
        return nil unless context.repository || context.job

        PromptContext.call(repository: context.repository, job: context.job)
      end
    end
  end
end
