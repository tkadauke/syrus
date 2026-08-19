# OperationalLogIndex/BrowserErrorIndex memoize table availability per
# process (see app/models/*_index.rb). Many specs manipulate the underlying
# sqlite_master state directly via raw SQL, bypassing the reset hook wired
# into SyrusSearchDatabaseTasks, so reset before every example to keep each
# spec's availability check independent of example run order.
RSpec.configure do |config|
  config.before do
    OperationalLogIndex.reset_availability_cache!
    BrowserErrorIndex.reset_availability_cache!
  end
end
