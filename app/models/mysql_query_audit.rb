class MysqlQueryAudit < ApplicationRecord
  belongs_to :mysql_connection
  belongs_to :user

  validates :statement, presence: true
end
