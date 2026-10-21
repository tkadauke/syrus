import { pendingActionToolCard } from "@app/routes/chat/pendingActionToolCard"

const adminMysqlKillQueryToolCard = pendingActionToolCard("admin_mysql_kill_query", {
  inputFields: [{ key: "thread_id", label: "MySQL thread", format: "badge" }]
})

export default adminMysqlKillQueryToolCard
