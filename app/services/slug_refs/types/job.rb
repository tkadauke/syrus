module SlugRefs
  module Types
    class Job
      include Syrus::Plugin::SlugType

      def self.prefix = "JOB"
      def self.display_label = "Job"
      def self.preview_available? = true

      def self.record_for(id, user:)
        record = ::Job.find_by(id: id)
        return nil unless record
        return record if ::JobPolicy.new(user, record).show?

        nil
      end

      def self.web_path(record)
        "/jobs/#{canonical_slug(record.id)}"
      end

      def self.api_preview_path(record)
        "/api/v1/app/jobs/#{canonical_slug(record.id)}"
      end
    end
  end
end
