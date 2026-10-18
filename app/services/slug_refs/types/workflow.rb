module SlugRefs
  module Types
    class Workflow
      include Syrus::Plugin::SlugType

      def self.prefix = "WF"
      def self.type_key = "workflow"
      def self.display_label = "Workflow"
      def self.preview_available? = true
      def self.record_for(id, user:)
        workflow = ::Workflow.includes(:job).find_by(id: id)
        return nil unless workflow
        return workflow if ::JobPolicy.new(user, workflow.job).show?

        nil
      end

      def self.web_path(record)
        "/jobs/#{record.job_id}?tab=workflows#workflow-#{record.id}"
      end

      def self.api_preview_path(record)
        "/api/v1/app/workflows/#{record.id}/preview"
      end
    end
  end
end
