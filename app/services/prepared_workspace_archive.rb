require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tmpdir"

class PreparedWorkspaceArchive
  CONTENT_TYPE = "application/gzip".freeze
  MAX_BYTES = 1.gigabyte

  def self.prepare_fingerprint_for(plan)
    Digest::SHA256.hexdigest(JSON.generate(
      "source" => plan.source,
      "note" => plan.note,
      "guessed" => plan.guessed?,
      "commands" => plan.commands
    ))
  end

  def self.publish!(...)
    new(...).publish!
  end

  def self.metadata(workflow:, snapshot:, plan:)
    {
      "workflow_id" => workflow.id,
      "source_snapshot_id" => snapshot.id,
      "source_sha" => snapshot.source_sha,
      "source_ref" => snapshot.source_ref,
      "tree_sha" => snapshot.tree_sha,
      "prepare_fingerprint" => prepare_fingerprint_for(plan),
      "prepare_source" => plan.source,
      "max_bytes" => MAX_BYTES,
      "uploaded_at" => Time.current.iso8601
    }.compact
  end

  def initialize(workflow:, snapshot:, step:, path:, plan: nil, log: nil)
    @workflow = workflow
    @snapshot = snapshot
    @step = step
    @path = Pathname.new(path)
    @plan = plan || RepoPrepPlan.for(@path)
    @log = log
  end

  def publish!
    return false if @snapshot.prepared_workspace_archive.attached? &&
      prepared_archive_metadata_matches?(@snapshot.prepared_workspace_archive.blob.metadata)

    archive_path = temporary_archive_path
    run_tar!(
      "tar",
      "--exclude=./.syrus/immutable-checkouts",
      "-czf",
      archive_path.to_s,
      "-C",
      @path.to_s,
      "."
    )
    archive_bytes = archive_path.size
    if archive_bytes > MAX_BYTES
      log("prepared archive upload skipped: #{archive_bytes} bytes exceeds #{MAX_BYTES} byte limit")
      return false
    end

    File.open(archive_path, "rb") do |file|
      @snapshot.prepared_workspace_archive.attach(
        io: file,
        filename: "workflow-source-snapshot-#{@snapshot.id}-prepared.tar.gz",
        content_type: CONTENT_TYPE,
        identify: false,
        metadata: metadata
      )
    end
    log("uploaded prepared workspace archive for snapshot ##{@snapshot.id}")
    true
  rescue StandardError => e
    log("prepared archive upload failed; continuing without archive: #{e.class}: #{e.message}")
    false
  ensure
    FileUtils.rm_f(archive_path.to_s) if archive_path
  end

  def metadata
    self.class.metadata(workflow: @workflow, snapshot: @snapshot, plan: @plan)
  end

  private

  def prepared_archive_metadata_matches?(metadata)
    metadata.to_h.slice(
      "workflow_id",
      "source_snapshot_id",
      "source_sha",
      "prepare_fingerprint"
    ) == self.metadata.slice(
      "workflow_id",
      "source_snapshot_id",
      "source_sha",
      "prepare_fingerprint"
    )
  end

  def temporary_archive_path
    Pathname.new(Dir.tmpdir).join(
      "syrus-prepared-workspace-#{@workflow.id}-#{@step.id}-#{Process.pid}-#{SecureRandom.hex(6)}.tar.gz"
    )
  end

  def run_tar!(*args)
    _stdout, stderr, status = Open3.capture3(*args)
    raise "tar failed: #{stderr.presence || status.exitstatus}" unless status.success?
  end

  def log(message)
    @log&.call("[prepared_workspace_archive] #{message}", kind: "system")
  end
end
