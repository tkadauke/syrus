# The fingerprint on a snapshot is what makes "has this dependency closure
# already been published?" an indexed question. Snapshots created before the
# column existed carry it only inside their archive's blob metadata, where the
# lookup cannot see it -- so without this backfill the publish dedupe would
# only start working for closures first seen after the deploy, and every
# already-published archive would be re-uploaded once more.
class BackfillPrepareFingerprintOnSnapshotsWithArchives < ActiveRecord::Migration[8.1]
  class Snapshot < ActiveRecord::Base
    self.table_name = "workflow_source_snapshots"
  end

  class Attachment < ActiveRecord::Base
    self.table_name = "active_storage_attachments"
  end

  class Blob < ActiveRecord::Base
    self.table_name = "active_storage_blobs"
  end

  def up
    return unless column_exists?(:workflow_source_snapshots, :prepare_fingerprint)

    attachments = Attachment.where(name: "prepared_workspace_archive", record_type: "WorkflowSourceSnapshot")
    attachments.in_batches(of: 200) do |batch|
      blobs = Blob.where(id: batch.pluck(:blob_id)).pluck(:id, :metadata).to_h
      batch.pluck(:record_id, :blob_id).each do |snapshot_id, blob_id|
        fingerprint = fingerprint_from(blobs[blob_id])
        next if fingerprint.blank?

        Snapshot.where(id: snapshot_id, prepare_fingerprint: nil).update_all(prepare_fingerprint: fingerprint)
      end
    end
  end

  def down
    # Leaving the backfilled values in place is harmless: the column is a cache
    # of what the blob metadata already says.
  end

  private

  def fingerprint_from(metadata)
    return nil if metadata.blank?

    JSON.parse(metadata)["prepare_fingerprint"].presence
  rescue JSON::ParserError
    nil
  end
end
