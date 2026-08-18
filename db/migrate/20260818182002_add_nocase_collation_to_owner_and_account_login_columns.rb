class AddNocaseCollationToOwnerAndAccountLoginColumns < ActiveRecord::Migration[8.1]
  # MySQL's utf8mb4 default collation (utf8mb4_general_ci / utf8mb4_0900_ai_ci) is
  # already case-insensitive, which is why lower(col) wrappers were removable there.
  # SQLite has no equivalent default, so give these columns an explicit NOCASE
  # collation to keep dev/test matching production's case-insensitive behavior now
  # that callers compare with plain equality instead of lower().
  def up
    return unless sqlite?

    change_column :repositories, :owner, :string, null: false, collation: "NOCASE"
    change_column :repositories, :name, :string, null: false, collation: "NOCASE"
    change_column :installations, :account_login, :string, null: false, collation: "NOCASE"
  end

  def down
    return unless sqlite?

    change_column :repositories, :owner, :string, null: false
    change_column :repositories, :name, :string, null: false
    change_column :installations, :account_login, :string, null: false
  end

  private

  def sqlite?
    connection.adapter_name.match?(/sqlite/i)
  end
end
