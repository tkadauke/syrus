require "rails_helper"

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
      ::Open3.capture3("git", "status")
      Runtime::Process.spawn("worker")
    RUBY

    expect(direct_launch_lines_for(source)).to eq((1..15).to_a)
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
    root = RubyVM::AbstractSyntaxTree.parse(source)

    each_ast_node(root).filter_map do |node|
      node.first_lineno if direct_launch_node?(node)
    end.uniq
  end

  def each_ast_node(node, &block)
    return enum_for(__method__, node) unless block

    yield node
    node.children.each do |child|
      each_ast_node(child, &block) if child.is_a?(RubyVM::AbstractSyntaxTree::Node)
    end
  end

  def direct_launch_node?(node)
    return true if %i[XSTR DXSTR].include?(node.type)
    return node.children.first == :system if node.type == :FCALL
    return false unless node.type == :CALL

    receiver, method_name = node.children
    constant = receiver.children.last.to_s if %i[CONST COLON2 COLON3].include?(receiver.type)
    constant && direct_process_method?(constant, method_name.to_s)
  end

  def direct_process_method?(constant, method_name)
    return method_name.start_with?("capture", "popen", "pipeline") if constant == "Open3"
    return method_name == "spawn" if constant == "Process"
    return method_name == "popen" if constant == "IO"

    constant == "Kernel" && method_name == "system"
  end
end
