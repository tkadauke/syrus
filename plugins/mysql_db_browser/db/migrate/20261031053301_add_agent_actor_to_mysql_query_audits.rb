class AddAgentActorToMysqlQueryAudits < ActiveRecord::Migration[8.1]
  def change
    add_reference :mysql_query_audits, :agent_actor, polymorphic: true, null: true, if_not_exists: true
  end
end
