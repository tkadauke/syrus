module SyrusMcp
  def self.run_from_context(server_context)
    with_database_connection do
      run_id = server_context[:run_id] || server_context[:run]&.id
      Run.find(run_id)
    end
  end

  def self.with_database_connection
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.verify! if connection.respond_to?(:verify!)
      yield
    end
  end

  # Append a JobLog row from the sidecar process. Same shape as
  # RunJob#log so MCP-driven lines blend into the rest of the
  # transcript and broadcast live via JobLog#broadcasts_to.
  def self.write_log(run, chunk)
    with_database_connection do
      next_seq = (run.job_logs.maximum(:sequence) || -1) + 1
      run.job_logs.create!(chunk: chunk, sequence: next_seq)
    end
  end
end
