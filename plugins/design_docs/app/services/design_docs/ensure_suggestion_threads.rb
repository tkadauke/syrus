module DesignDocs
  class EnsureSuggestionThreads
    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:)
      @design_doc = design_doc
    end

    def call
      design_doc.with_lock do
        pending_suggestions_without_threads.find_each do |suggestion|
          suggestion.update!(thread: thread_for(suggestion))
        end
      end

      design_doc.reload
    end

    private

    attr_reader :design_doc

    def pending_suggestions_without_threads
      design_doc.suggestions
        .includes(:anchor)
        .where(state: "pending", design_doc_thread_id: nil)
    end

    def thread_for(suggestion)
      design_doc.threads.create!(
        anchor: suggestion.anchor,
        opened_by_user: suggestion.suggested_by_kind == "user" ? suggestion.suggested_by_user : nil
      )
    end
  end
end
