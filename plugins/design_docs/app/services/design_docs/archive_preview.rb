module DesignDocs
  class ArchivePreview
    FAST_PATH_MAX_AGE = 10.minutes

    def self.payload(design_doc)
      new(design_doc).payload
    end

    def self.confirmation_reason(design_doc)
      new(design_doc).confirmation_reason
    end

    def initialize(design_doc)
      @design_doc = design_doc
    end

    def payload
      {
        doc_ref: design_doc.display_id,
        design_doc_id: design_doc.id,
        title: design_doc.title,
        state: design_doc.state,
        age: helpers.distance_of_time_in_words(design_doc.created_at, Time.current),
        age_seconds: (Time.current - design_doc.created_at).to_i,
        current_version_number: current_version_number,
        threads_count: design_doc.threads.count,
        comments_count: comments_count,
        suggestions_count: design_doc.suggestions.count,
        repository_ids: design_doc.repositories.pluck(:id),
        repository_slugs: design_doc.repositories.map(&:slug),
        confirmation_reason: confirmation_reason
      }
    end

    def confirmation_reason
      reasons = []
      reasons << "current version is v#{current_version_number || "unknown"}" unless current_version_number == 1
      reasons << "doc is older than 10 minutes" if design_doc.created_at < FAST_PATH_MAX_AGE.ago
      reasons << "doc has #{design_doc.threads.count} thread(s)" if design_doc.threads.exists?
      reasons << "doc has #{comments_count} comment(s)" if comments_count.positive?
      reasons << "doc has #{design_doc.suggestions.count} suggestion(s)" if design_doc.suggestions.exists?
      reasons.presence&.to_sentence || "confirmation required before archiving"
    end

    private

    attr_reader :design_doc

    def current_version_number
      design_doc.current_version&.version_number
    end

    def comments_count
      DesignDocs::DesignDocComment.joins(:thread).where(design_doc_threads: { design_doc_id: design_doc.id }).count
    end

    def helpers
      ActionController::Base.helpers
    end
  end
end
