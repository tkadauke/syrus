class AddInstallationToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_reference :repositories, :installation, foreign_key: true
  end
end
