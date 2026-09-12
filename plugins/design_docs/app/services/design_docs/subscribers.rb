module DesignDocs
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      {
        "design_doc.upserted" => :on_design_doc_upserted,
        "design_doc.deleted" => :on_design_doc_deleted
      }
    end

    def self.on_design_doc_upserted(event)
      return unless DesignDocs::SearchSource.enabled?

      DesignDocs::IndexSearchJob.perform_later(event.fetch(:design_doc_id))
    end

    def self.on_design_doc_deleted(event)
      return unless DesignDocs::SearchSource.enabled?

      DesignDocs::SearchIndex.delete(event.fetch(:design_doc_id))
    end
  end
end
