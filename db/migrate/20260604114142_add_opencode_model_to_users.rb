class AddOpencodeModelToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :opencode_model, :string
  end
end
