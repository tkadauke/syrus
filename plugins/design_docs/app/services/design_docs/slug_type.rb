module DesignDocs
  # Behavior for the `slug_type` manifest declaration in design_docs.rb, which
  # owns the prefix, label and client path.
  class SlugType
    def self.record_for(id, user:)
      return nil unless user

      DesignDocs::DesignDoc.visible_to(user).find_by(id: id)
    end

    def self.web_path(record)
      "/design_docs/#{record.id}"
    end

    def self.api_preview_path(record)
      "/api/v1/app/design_docs/#{record.id}/preview"
    end
  end
end
