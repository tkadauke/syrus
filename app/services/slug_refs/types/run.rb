module SlugRefs
  module Types
    class Run
      include Syrus::Plugin::SlugType

      def self.prefix = "RUN"
      def self.display_label = "Run"

      def self.record_for(id, user:)
        run = ::Run.includes(step: { workflow: :job }).find_by(id: id)
        return nil unless run
        return run if ::JobPolicy.new(user, run.job).show?

        nil
      end

      def self.web_path(record)
        workflow = record.workflow
        return "/jobs/#{record.job_id}" unless workflow

        "/jobs/#{workflow.job_id}?tab=workflows#workflow-#{workflow.id}"
      end
    end
  end
end
