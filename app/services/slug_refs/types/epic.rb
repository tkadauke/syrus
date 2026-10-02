module SlugRefs
  module Types
    class Epic
      include Syrus::Plugin::SlugType

      def self.prefix = "EPIC"
      def self.display_label = "Epic"
      def self.preview_available? = true
      def self.client_path(number) = "/epics/#{canonical_slug(number)}"

      def self.record_for(number, user:)
        scope = user&.admin? ? ::Epic.all : ::Epic.accessible_to(user)
        scope.find_by(number: number)
      end

      def self.web_path(record)
        "/epics/#{canonical_slug(record.number)}"
      end

      def self.api_preview_path(record)
        "/api/v1/app/epics/#{canonical_slug(record.number)}"
      end
    end
  end
end
