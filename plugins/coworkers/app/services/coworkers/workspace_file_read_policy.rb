class Coworkers::WorkspaceFileReadPolicy
  MAX_BYTES = 64.kilobytes
  TRUNCATION_MARKER = "[truncated at the coworker memory cap]".freeze
  MEMORY_PATH = %r{\Amemory/(?:daily|people|repos|banks)/.+\.md\z}

  def self.for(relative_path)
    new if relative_path.to_s.match?(MEMORY_PATH)
  end

  def max_bytes = MAX_BYTES
  def truncation_marker = TRUNCATION_MARKER
end
