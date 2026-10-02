module DesignDocs
  class SlugType
    include Syrus::Plugin::SlugType

    def self.prefix = "DOC"
    def self.display_label = "Design Doc"
    def self.preview_available? = true
    def self.client_path(id) = "/design_docs/#{id}"

    def self.record_for(id, user:)
      return nil unless user

      DesignDocs::DesignDoc.visible_to(user).find_by(id: id)
    end

    def self.web_path(record)
      client_path(record.id)
    end

    def self.api_preview_path(record)
      "/api/v1/app/design_docs/#{record.id}/preview"
    end
  end
end
