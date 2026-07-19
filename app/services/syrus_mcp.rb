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
      JobLog.append!(run: run, chunk: chunk)
    end
  end

  def self.invalid(reason)
    MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
  end

  def self.not_authorized
    MCP::Tool::Response.new([ { type: "text", text: { error: "not_authorized" }.to_json } ], error: true)
  end

  def self.utf8(text)
    string = text.to_s
    if string.encoding == Encoding::ASCII_8BIT
      string.dup.force_encoding(Encoding::UTF_8).scrub("")
    else
      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    end
  end
end
