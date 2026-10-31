class AddAgentActorToMysqlQueryAudits < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:mysql_query_audits, :agent_actor_id)
      add_reference :mysql_query_audits, :agent_actor, polymorphic: true, null: true
    end
  end
end
