class CreateGithubIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :github_issues_synced_at, :datetime unless column_exists?(:repositories, :github_issues_synced_at)
    add_column :repositories, :github_issues_full_synced_at, :datetime unless column_exists?(:repositories, :github_issues_full_synced_at)

    create_table :github_issues do |t|
      t.references :repository, null: false
      t.bigint :github_id, null: false
      t.integer :number, null: false
      t.string :title, null: false
      t.text :body
      t.string :state, null: false
      t.string :html_url, null: false
      t.string :author_login
      t.json :labels, null: false
      t.datetime :github_created_at
      t.datetime :github_updated_at
      t.datetime :synced_at
      t.json :linked_open_pr
      t.datetime :linked_open_pr_checked_at

      t.timestamps
    end

    add_index :github_issues, [ :repository_id, :github_id ], unique: true unless index_exists?(:github_issues, [ :repository_id, :github_id ])
    add_index :github_issues, [ :repository_id, :number ], unique: true unless index_exists?(:github_issues, [ :repository_id, :number ])
    add_index :github_issues, [ :repository_id, :state ] unless index_exists?(:github_issues, [ :repository_id, :state ])
  end
end
