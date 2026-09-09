module WorkflowSourceSnapshots
  class Recorder
    def self.record!(...) = new(...).record!
    def self.current_for(workflow) = WorkflowSourceSnapshot.current_for(workflow)

    def initialize(workflow:, source_sha:, source_ref:, creator_step:, tree_sha: nil, source_fingerprint: nil, published_at: Time.current)
      @workflow = workflow
      @source_sha = source_sha
      @source_ref = source_ref
      @creator_step = creator_step
      @tree_sha = tree_sha
      @source_fingerprint = source_fingerprint
      @published_at = published_at
    end

    def record!
      snapshot = WorkflowSourceSnapshot.find_or_initialize_by(workflow: workflow, source_sha: source_sha)
      snapshot.assign_attributes(
        source_ref: source_ref,
        tree_sha: tree_sha,
        source_fingerprint: source_fingerprint,
        creator_step: creator_step,
        published_at: published_at
      )
      snapshot.save!
      snapshot
    end

    private

    attr_reader :workflow, :source_sha, :source_ref, :creator_step, :tree_sha, :source_fingerprint, :published_at
  end
end
