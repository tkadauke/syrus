require "rails_helper"

RSpec.describe FocusedTestCommandTemplate do
  it "preserves shell escaping while replacing file and count placeholders" do
    files = [
      "spec/a\\;id;b_spec.rb",
      "spec/ampersand&name_spec.rb",
      "spec/single'quote_spec.rb",
      "spec/`backtick`_spec.rb"
    ]

    command = described_class.interpolate(
      "bin/test {files} --count {failed_count} --again {files}",
      files: files,
      failed_count: files.size
    )

    escaped_files = Shellwords.join(files)
    expect(command).to eq("bin/test #{escaped_files} --count 4 --again #{escaped_files}")
    expect(Shellwords.split(command)).to eq(
      [ "bin/test", *files, "--count", "4", "--again", *files ]
    )
  end
end
