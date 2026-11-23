module Syrus
  module Host
    # Read-only access to diff-review comments and versions.
    module DiffReviews
      def self.comments = ::DiffReviewComment.all
      def self.versions = ::DiffReviewVersion.all

      def self.best_match_version(job_id:, run_id:, workflow_id:)
        ::DiffReviewVersion.best_match_for(job_id:, run_id:, workflow_id:)
      end

      def self.final_review_version(job:, workflow:, run:)
        ::DiffReviewVersions::FinalReviewVersion.resolve(job:, workflow:, run:)
      end
    end
  end
end
