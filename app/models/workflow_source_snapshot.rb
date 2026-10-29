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

  # Attaches the prepared archive, tolerating a concurrent winner.
  #
  # Grader fanout puts several graders on one snapshot across several workers,
  # and each of them independently resolves the same reusable blob, sees the
  # snapshot unattached, and attaches it. The attachment uniqueness index then
  # rejects whichever insert arrives second with RecordNotUnique, and a Run
  # that had done nothing wrong died classified as an application error.
  #
  # Losing that race is success: the snapshot ends up with exactly the blob
  # this caller wanted on it. Only a *different* blob winning is worth
  # reporting, and the caller gets `false` for that rather than an exception,
  # because publishing an archive is an optimization and must never be able to
  # fail the work that triggered it.
  def attach_prepared_workspace_archive(blob)
    prepared_workspace_archive.attach(blob)
    true
  rescue ActiveRecord::RecordNotUnique
    reload
    attached = prepared_workspace_archive.attached? &&
      prepared_workspace_archive.blob.id == blob.id
    Rails.logger.info(
      "[WorkflowSourceSnapshot] prepared archive attach race on ##{id}; " \
        "#{attached ? "another worker attached the same blob" : "another blob won"}"
    )
    attached
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
