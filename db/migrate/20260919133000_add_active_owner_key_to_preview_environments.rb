class AddActiveOwnerKeyToPreviewEnvironments < ActiveRecord::Migration[8.1]
  ACTIVE_STATES = %w[starting seeding running stopping].freeze
  CONFLICT_ERROR_REASON = "active_preview_conflict"
  CONFLICT_ERROR_MESSAGE = "Superseded by another active preview environment during active-owner uniqueness backfill."

  class PreviewEnvironment < ActiveRecord::Base
    self.table_name = "preview_environments"
  end

  def up
    add_column :preview_environments, :active_owner_key, :string unless column_exists?(:preview_environments, :active_owner_key)

    PreviewEnvironment.reset_column_information
    retire_duplicate_active_previews!
    backfill_active_owner_keys!

    unless index_exists?(:preview_environments, :active_owner_key, name: "idx_preview_environments_active_owner_key_unique")
      add_index :preview_environments,
                :active_owner_key,
                unique: true,
                name: "idx_preview_environments_active_owner_key_unique"
    end
  end

  def down
    if index_exists?(:preview_environments, :active_owner_key, name: "idx_preview_environments_active_owner_key_unique")
      remove_index :preview_environments, name: "idx_preview_environments_active_owner_key_unique"
    end

    remove_column :preview_environments, :active_owner_key if column_exists?(:preview_environments, :active_owner_key)
  end

  private

  def retire_duplicate_active_previews!
    duplicate_job_ids = active_scope.where.not(job_id: nil).group(:job_id).having("COUNT(*) > 1").pluck(:job_id)
    duplicate_job_ids.each do |job_id|
      retire_duplicate_rows(active_scope.where(job_id: job_id))
    end

    duplicate_repository_ids = active_scope.where(job_id: nil).where.not(repository_id: nil).group(:repository_id).having("COUNT(*) > 1").pluck(:repository_id)
    duplicate_repository_ids.each do |repository_id|
      retire_duplicate_rows(active_scope.where(job_id: nil, repository_id: repository_id))
    end
  end

  def retire_duplicate_rows(scope)
    keep = scope.order(created_at: :desc, id: :desc).first
    scope.where.not(id: keep.id).update_all(
      state: "failed",
      error_reason: CONFLICT_ERROR_REASON,
      error_message: CONFLICT_ERROR_MESSAGE,
      updated_at: Time.current
    )
  end

  def backfill_active_owner_keys!
    PreviewEnvironment.where(state: ACTIVE_STATES).find_each do |env|
      key =
        if env.job_id.present?
          "job:#{env.job_id}"
        elsif env.repository_id.present?
          "repository:#{env.repository_id}"
        end
      env.update_columns(active_owner_key: key) if key.present?
    end
  end

  def active_scope
    PreviewEnvironment.where(state: ACTIVE_STATES)
  end
end
