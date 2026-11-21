# Every branch head Syrus itself pushed, so a later step can tell Syrus's own
# superseded output on a PR branch apart from commits someone else pushed.
class CreateBranchPublications < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:branch_publications)
      create_table :branch_publications do |t|
        t.string :branch_name, null: false
        t.string :sha, null: false, limit: 64
        t.bigint :workflow_id
        t.datetime :created_at, null: false
      end
    end
    unless index_exists?(:branch_publications, [ :branch_name, :sha ], name: "idx_branch_publications_branch_sha")
      add_index :branch_publications, [ :branch_name, :sha ], unique: true, name: "idx_branch_publications_branch_sha"
    end
    unless index_exists?(:branch_publications, :created_at, name: "idx_branch_publications_created_at")
      add_index :branch_publications, :created_at, name: "idx_branch_publications_created_at"
    end
  end
end
