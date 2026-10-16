class WorkflowSourceSnapshot < ApplicationRecord
  belongs_to :workflow
  belongs_to :creator_step, class_name: "Step"
  has_one_attached :prepared_workspace_archive

  validates :source_sha, :source_ref, :published_at, presence: true
  validate :has_tree_identity
  validate :creator_step_belongs_to_workflow

  scope :published, -> { where.not(published_at: nil) }
  scope :newest_first, -> { order(published_at: :desc, id: :desc) }

  def tree_identity
    tree_sha.presence || fingerprint.presence
  end

  # Finds a published archive this snapshot can reuse: same prepare
  # fingerprint, which already covers the prepare plan and the worker
  # capability environment, so the dependency closure inside it is the one
  # this snapshot would have uploaded.
  def self.reusable_prepared_archive_for(prepare_fingerprint)
    return nil if prepare_fingerprint.blank?

    where(prepare_fingerprint: prepare_fingerprint)
      .where.associated(:prepared_workspace_archive_attachment)
      .includes(prepared_workspace_archive_attachment: :blob)
      .order(id: :desc)
      .find { |snapshot| snapshot.prepared_workspace_archive.attached? }
      &.prepared_workspace_archive
  end

  # One blob now backs every snapshot that shares a prepare fingerprint, so
  # purging it because *this* snapshot's workflow was cleaned up would delete
  # the archive the others still point at. Detach instead whenever the blob is
  # shared, and let the last attachment take the blob with it.
  def purge_prepared_workspace_archive!
    return unless prepared_workspace_archive.attached?
    return prepared_workspace_archive.purge unless prepared_archive_blob_shared?

    prepared_workspace_archive.detach
  end



  private

  def prepared_archive_blob_shared?
    ActiveStorage::Attachment
      .where(blob_id: prepared_workspace_archive.blob.id)
      .where.not(id: prepared_workspace_archive.attachment.id)
      .exists?
  end

  def has_tree_identity
    return if tree_identity.present?

    errors.add(:base, "tree_sha or fingerprint must be present")
  end

  def creator_step_belongs_to_workflow
    return if creator_step.blank? || workflow.blank?
    return if creator_step.workflow_id == workflow.id

    errors.add(:creator_step, "must belong to the same workflow")
  end
end
