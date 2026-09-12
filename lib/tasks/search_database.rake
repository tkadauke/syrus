require Rails.root.join("app/services/syrus_search_database_tasks")

namespace :syrus do
  desc "Create and migrate the local search database"
  task prepare_search: :environment do
    SyrusSearchDatabaseTasks.prepare_with_lock!
  end
end
