module DesignDocs
  class IndexSearchJob < Syrus::Host::PluginJob
    plugin :design_docs

    def perform(design_doc_id)
      design_doc = DesignDocs::DesignDoc.find_by(id: design_doc_id)
      if design_doc
        DesignDocs::SearchIndex.upsert(design_doc)
      else
        DesignDocs::SearchIndex.delete(design_doc_id)
      end
    end
  end
end
