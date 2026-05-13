class GitInfoExclude
  def self.ensure_entry!(repository_path, entry)
    new(repository_path).ensure_entry!(entry)
  end

  def initialize(repository_path)
    @repository_path = Pathname.new(repository_path)
  end

  def ensure_entry!(entry)
    exclude_path = @repository_path.join(".git", "info", "exclude")
    lines = exclude_path.exist? ? exclude_path.read.lines.map(&:chomp) : []
    return if lines.include?(entry)

    File.open(exclude_path, "a") do |file|
      file.write("\n") unless exclude_path.zero?
      file.puts(entry)
    end
  end
end
