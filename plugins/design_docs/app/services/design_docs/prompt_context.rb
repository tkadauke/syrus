module DesignDocs
  class PromptContext
    MAX_DOCS = 8

    def self.call(repository:, job:)
      new.call(repository: repository, job: job)
    end

    def call(repository:, job:)
      return nil unless repository && job&.user

      docs = DesignDoc.visible_to(job.user)
        .joins(:design_doc_repositories)
        .where(design_doc_repositories: { repository_id: repository.id })
        .includes(:current_version)
        .newest_first
        .limit(MAX_DOCS)
        .to_a
      return nil if docs.empty?

      lines = docs.map do |doc|
        "- #{doc.display_id}: #{doc.title} (#{doc.visibility}, #{doc.state}, current version #{doc.current_version&.version_number || 'unknown'})"
      end
      lines << "- ... more readable design docs may be available through list_design_docs" if docs.size == MAX_DOCS

      <<~TEXT.strip
        ## Design Docs Context

        Readable design docs linked to this repository:
        #{lines.join("\n")}

        Use read_design_doc with a DOC-<id> reference when a listed design doc may affect this work. Workflow agents only have read-only design doc tools; do not attempt to mutate design docs from a worker run.
      TEXT
    end
  end
end
