require "rails_helper"

RSpec.describe "runtime process execution boundary" do
  it "keeps production Rails process launches behind ProcessRunner" do
    allowed = Rails.root.join("app/services/process_runner.rb").to_s
    violations = Dir[Rails.root.join("app/**/*.rb")].flat_map do |path|
      next [] if path == allowed

      File.readlines(path).filter_map.with_index(1) do |line, line_number|
        source = line.sub(/#.*/, "")
        next unless source.match?(/Open3\.|Process\.spawn|\bsystem\s*\(/)

        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{line_number}: #{line.strip}"
      end
    end

    expect(violations).to eq([]), <<~MESSAGE
      Production Rails commands must use GitRunner for ordinary Git operations
      or ProcessRunner for other binaries. Direct process launches found:
      #{violations.join("\n")}
    MESSAGE
  end
end
