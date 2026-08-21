# JobLog.append! memoizes the next sequence number per run_id in a
# thread-local cache (see app/models/job_log.rb). Under SQLite transactional
# fixtures, a rolled-back insert also rolls back the AUTOINCREMENT counter, so
# a later example's Run can be assigned the very same id an earlier example
# already cached a sequence for. Reset before every example so a leaked
# sequence from one spec doesn't seed the next Run that happens to reuse the id.
RSpec.configure do |config|
  config.before do
    JobLog.clear_sequence_cache!
  end
end
