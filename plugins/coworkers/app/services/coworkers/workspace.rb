class Coworkers::Workspace
  class InvalidPath < ArgumentError; end

  def self.for(server_context)
    run = server_context[:run]
    root = StepWorkspace.for(run.step, run: run).path if run&.step&.kind == "coworker_run"
    new(server_context.fetch(:chat_session), root: root)
  end

  def initialize(chat_session, root: nil)
    @chat_session = chat_session
    link = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat_session.id)
    repository = link&.coworker&.workspace_repository
    raise InvalidPath, "coworker workspace is unavailable" unless repository

    @root = (root || ChatWorkspace.repo_path_for(chat_session, repository)).expand_path
  end

  def write(path, content)
    target = resolve(path, allow_missing: true)
    FileUtils.mkdir_p(target.dirname)
    File.write(target, content.to_s)
    relative(target)
  end

  def edit(path, old_text, new_text, replace_all: false)
    raise InvalidPath, "old_text must not be empty" if old_text.to_s.empty?

    target = resolve(path)
    content = File.read(target)
    occurrences = content.scan(old_text.to_s).length
    raise InvalidPath, "old_text was not found" if occurrences.zero?
    raise InvalidPath, "old_text occurs more than once; set replace_all to edit every occurrence" if occurrences > 1 && !replace_all

    updated = replace_all ? content.gsub(old_text.to_s, new_text.to_s) : content.sub(old_text.to_s, new_text.to_s)
    File.write(target, updated)
    relative(target)
  end

  def move(source, destination)
    source_path = resolve(source)
    destination_path = resolve(destination, allow_missing: true)
    raise InvalidPath, "destination already exists" if destination_path.exist? || destination_path.symlink?

    FileUtils.mkdir_p(destination_path.dirname)
    FileUtils.mv(source_path, destination_path)
    { source: relative(source_path), destination: relative(destination_path) }
  end

  def delete(path)
    target = resolve(path)
    raise InvalidPath, "directories must be empty before deletion" if target.directory? && target.children.any?

    target.directory? ? Dir.rmdir(target) : File.delete(target)
    relative(target)
  end

  private

  def resolve(path, allow_missing: false)
    relative_path = Pathname.new(path.to_s)
    raise InvalidPath, "path must be relative to the coworker workspace" if path.blank? || relative_path.absolute?

    clean = relative_path.cleanpath
    raise InvalidPath, "path escapes the coworker workspace" if clean.to_s == ".." || clean.each_filename.first == ".."
    raise InvalidPath, "the Git metadata directory is orchestrator-owned" if clean.each_filename.first == ".git"

    root = resolved_root
    target = root.join(clean)
    verify_ancestors!(root, target, include_target: target.exist? || target.symlink?)
    raise InvalidPath, "path does not exist" unless allow_missing || target.exist?
    target
  rescue Errno::ENOENT
    raise InvalidPath, "coworker workspace is unavailable"
  end

  def verify_ancestors!(root, target, include_target:)
    cursor = include_target ? target : target.dirname
    until cursor == root
      raise InvalidPath, "path escapes the coworker workspace" unless cursor.to_s.start_with?("#{root}/")
      raise InvalidPath, "symbolic links are not accessible" if cursor.symlink?
      cursor = cursor.dirname
    end
  end

  # Measured from the same root the target was built against. `resolve` works
  # from the realpath, so relativizing against the configured root answered
  # with a path full of `..` segments whenever the root reaches the workspace
  # through a symlink -- true of any symlinked data root, and of every macOS
  # temp directory, where /var is a link to /private/var.
  def relative(path) = path.relative_path_from(resolved_root).to_s

  def resolved_root = @resolved_root ||= @root.realpath
end
