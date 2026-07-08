class BackfillInputSourcesData < ActiveRecord::Migration[8.1]
  def up
    # Enforce non-null config now that the table exists and rows are about to be inserted.
    execute "UPDATE input_sources SET config = '{}' WHERE config IS NULL"
    change_column_null :input_sources, :config, false

    # Create an InputSources::Github record for every existing repository.
    repo_to_source = {}
    Repository.find_each do |repo|
      next if repo.user_id.nil?

      source = InputSource.find_or_create_by!(
        type: "InputSources::Github",
        repository_id: repo.id
      ) do |s|
        s.user_id = repo.user_id
        s.polling_enabled = repo.read_attribute(:polling_enabled)
        s.config = { "trigger_label" => repo.read_attribute(:trigger_label) }
      end
      repo_to_source[repo.id] = source.id
    end

    # Backfill external_ref and input_source_id for all existing issue-kind Jobs.
    repo_to_source.each do |repo_id, source_id|
      Job.where(repository_id: repo_id, kind: "issue")
         .where(external_ref: nil)
         .where.not(issue_number: nil)
         .find_each do |job|
           job.update_columns(
             external_ref: job.issue_number.to_s,
             input_source_id: source_id
           )
         end
    end
  end

  def down
    Job.where.not(input_source_id: nil).update_all(input_source_id: nil, external_ref: nil)
    InputSource.delete_all

    change_column_null :input_sources, :config, true
  end
end
