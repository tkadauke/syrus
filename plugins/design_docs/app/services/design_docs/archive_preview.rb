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
      loaded_repositories = repositories
      {
        doc_ref: design_doc.display_id,
        design_doc_id: design_doc.id,
        title: design_doc.title,
        state: design_doc.state,
        age: helpers.distance_of_time_in_words(design_doc.created_at, Time.current),
        age_seconds: (Time.current - design_doc.created_at).to_i,
        current_version_number: current_version_number,
        threads_count: threads_count,
        comments_count: comments_count,
        suggestions_count: suggestions_count,
        repository_ids: loaded_repositories.map(&:id),
        repository_slugs: loaded_repositories.map(&:slug),
        confirmation_reason: confirmation_reason
      }
    end

    def confirmation_reason
      reasons = []
      reasons << "current version is v#{current_version_number || "unknown"}" unless current_version_number == 1
      reasons << "doc is older than 10 minutes" if design_doc.created_at < FAST_PATH_MAX_AGE.ago
      reasons << "doc has #{threads_count} thread(s)" if threads_count.positive?
      reasons << "doc has #{comments_count} comment(s)" if comments_count.positive?
      reasons << "doc has #{suggestions_count} suggestion(s)" if suggestions_count.positive?
      reasons.presence&.to_sentence || "confirmation required before archiving"
    end

    private

    attr_reader :design_doc

    def current_version_number
      design_doc.current_version&.version_number
    end

    def comments_count
      @comments_count ||= design_doc.comments_count
    end

    def threads_count
      @threads_count ||= association_count(:threads)
    end

    def suggestions_count
      @suggestions_count ||= association_count(:suggestions)
    end

    def association_count(name)
      association = design_doc.association(name)
      association.loaded? ? association.target.size : association.scope.count
    end

    def repositories
      @repositories ||= design_doc.repositories.load.to_a
    end

    def helpers
      ActionController::Base.helpers
    end
  end
end
