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

  def direct_launch_lines(path)
    tokens = Ripper.lex(File.read(path)).reject do |(_position, event, _token, _state)|
      %i[on_sp on_nl on_ignored_nl on_comment].include?(event)
    end

    tokens.each_with_index.filter_map do |entry, index|
      position, event, token, state = entry
      previous = tokens[index - 1]
      following = tokens[index + 1, 3]&.map { |entry| entry[2] }
      direct_constant_call = event == :on_const && %w[Open3 Process IO Kernel].include?(token) &&
        following&.first == "." && direct_process_method?(token, following[1])
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
