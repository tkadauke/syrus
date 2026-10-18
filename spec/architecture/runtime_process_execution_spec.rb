require "rails_helper"
require "ripper"

RSpec.describe "runtime process execution boundary" do
  it "keeps production Rails process launches behind ProcessRunner" do
    allowed = Rails.root.join("app/services/process_runner.rb").to_s
    production_files = %w[app lib plugins].flat_map { |directory| Dir[Rails.root.join("#{directory}/**/*.rb")] }
      .reject { |path| Pathname.new(path).each_filename.include?("spec") }
    violations = production_files.flat_map do |path|
      next [] if path == allowed

      direct_launch_lines(path).map do |line_number|
        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{line_number}: #{File.readlines(path)[line_number - 1].strip}"
      end
    end

    expect(violations).to eq([]), <<~MESSAGE
      Production Rails commands must use GitRunner for ordinary Git operations
      or ProcessRunner for other binaries. Direct process launches found:
      #{violations.join("\n")}
    MESSAGE
  end

  it "recognizes every supported direct-launch form" do
    source = <<~'RUBY'
      Open3.capture3("git", "status")
      Open3::popen3("git", "status")
      Open3.pipeline_r([ "printf", "hello" ], [ "cat" ])
      Process.spawn("worker")
      Process::spawn("worker")
      IO.popen("worker")
      IO::popen("worker")
      Kernel.system("worker")
      Kernel::system("worker")
      system("worker")
      system "worker"
      `worker`
      %x(worker)
    RUBY

    expect(direct_launch_lines_for(source)).to eq((1..13).to_a)
  end

  it "ignores process syntax in generated source text and non-call identifiers" do
    source = <<~'RUBY'
      generated = <<~'SCRIPT'
        Process::spawn("worker")
        system("worker")
        `worker`
      SCRIPT
      system = "operating system"
      metadata = { system: system }
    RUBY

    expect(direct_launch_lines_for(source)).to eq([])
  end

  def direct_launch_lines(path)
    direct_launch_lines_for(File.read(path))
  end

  def direct_launch_lines_for(source)
    tokens = Ripper.lex(source).reject do |(_position, event, _token, _state)|
      %i[on_sp on_nl on_ignored_nl on_comment].include?(event)
    end

    tokens.each_with_index.filter_map do |entry, index|
      position, event, token, state = entry
      previous = tokens[index - 1]
      following = tokens[index + 1, 3]&.map { |entry| entry[2] }
      direct_constant_call = event == :on_const && %w[Open3 Process IO Kernel].include?(token) &&
        %w[. ::].include?(following&.first) && direct_process_method?(token, following[1])
      bare_system_call = event == :on_ident && token == "system" &&
        state.to_s.include?("CMDARG") && !%w[: =].include?(following&.first) && previous&.dig(2) != "def"

      position.first if direct_constant_call || bare_system_call || event == :on_backtick
    end.uniq
  end

  def direct_process_method?(constant, method_name)
    return method_name.start_with?("capture", "popen", "pipeline") if constant == "Open3"
    return method_name == "spawn" if constant == "Process"
    return method_name == "popen" if constant == "IO"

    constant == "Kernel" && method_name == "system"
  end
end
