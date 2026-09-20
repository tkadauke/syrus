class CreateBootstrapLocks < ActiveRecord::Migration[8.1]
  def change
    create_table :bootstrap_locks do |t|
      t.string :name, null: false

      t.timestamps
    end

    add_index :bootstrap_locks, :name, unique: true unless index_exists?(:bootstrap_locks, :name)
  end
end
