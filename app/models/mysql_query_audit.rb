class MysqlQueryAudit < ApplicationRecord
  belongs_to :mysql_connection
  belongs_to :user
  belongs_to :agent_actor, polymorphic: true, optional: true

  validates :statement, presence: true
end
