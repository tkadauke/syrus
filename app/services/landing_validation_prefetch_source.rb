class LandingValidationPrefetchSource
  SOURCE_REF_PREFIX = "prefetch-bundle:".freeze

  def self.publish!(source_workflow:, child_workflow:, path:, source_sha:, tree_sha:, git: GitRunner.new)
    new(child_workflow).publish!(source_workflow:, path:, source_sha:, tree_sha:, git:)
  end

  def self.with_bundle(workflow, snapshot_id)
    snapshot = workflow.source_snapshots.find(snapshot_id)
    raise WorkflowSourceSnapshots::InfrastructureStateError, "landing validation prefetch snapshot bundle is missing" unless snapshot.source_bundle.attached?

    Tempfile.create([ "landing-validation-prefetch", ".bundle" ], binmode: true) do |file|
      snapshot.source_bundle.download { |chunk| file.write(chunk) }
      file.flush
      yield snapshot, file.path
    end
  end

  def self.release!(workflow)
    workflow.source_snapshots.where("source_ref LIKE ?", "#{SOURCE_REF_PREFIX}%").find_each do |snapshot|
      snapshot.source_bundle.purge if snapshot.source_bundle.attached?
      snapshot.destroy!
    end
  end

  def initialize(child_workflow)
    @child_workflow = child_workflow
  end

  def publish!(source_workflow:, path:, source_sha:, tree_sha:, git:)
    actual_sha = git.run("rev-parse", "HEAD", chdir: path.to_s, workflow: source_workflow).strip
    actual_tree = git.run("rev-parse", "HEAD^{tree}", chdir: path.to_s, workflow: source_workflow).strip
    unless actual_sha == source_sha && actual_tree == tree_sha
      raise WorkflowSourceSnapshots::InfrastructureStateError, "landing validation prefetch source changed before snapshot publication"
    end

    Tempfile.create([ "landing-validation-prefetch", ".bundle" ]) do |file|
      file.close
      git.run("bundle", "create", file.path, "HEAD", chdir: path.to_s, workflow: source_workflow)
      snapshot = WorkflowSourceSnapshots.record!(
        workflow: child_workflow,
        creator_step: child_workflow.steps.first,
        source_sha: source_sha,
        tree_sha: tree_sha,
        source_ref: "#{SOURCE_REF_PREFIX}#{child_workflow.id}"
      )
      blob = File.open(file.path, "rb") do |bundle|
        ActiveStorage::Blob.create_and_upload!(
          io: bundle,
          filename: "landing-validation-prefetch-#{child_workflow.id}.bundle",
          content_type: "application/x-git-bundle"
        )
      end
      snapshot.source_bundle.attach(blob)
      snapshot
    end
  end

  private

  attr_reader :child_workflow
end
