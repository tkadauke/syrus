require "rails_helper"

RSpec.describe Coverage::CoberturaParser do
  def fixture(name)
    Rails.root.join("spec/fixtures/coverage/#{name}").read
  end

  describe "#parse" do
    it "parses line data from a valid Cobertura XML fixture" do
      result = described_class.new(fixture("sample.xml")).parse

      user = result[:files]["app/models/user.rb"]
      expect(user[:lines]).to eq(1 => 3, 2 => 0, 5 => 1, 10 => 2)
    end

    it "includes all class files from the fixture" do
      result = described_class.new(fixture("sample.xml")).parse

      expect(result[:files].keys).to contain_exactly(
        "app/models/user.rb",
        "app/controllers/users_controller.rb",
        "app/models/post.rb"
      )
    end

    it "sets branches and functions to nil (not in Cobertura line-level data)" do
      result = described_class.new(fixture("sample.xml")).parse

      result[:files].each_value do |file_data|
        expect(file_data[:branches]).to be_nil
        expect(file_data[:functions]).to be_nil
      end
    end

    it "strips an absolute workspace prefix from paths" do
      xml = <<~XML
        <?xml version="1.0" ?>
        <coverage>
          <packages><package><classes>
            <class filename="/srv/app/models/user.rb">
              <lines><line number="1" hits="2"/></lines>
            </class>
          </classes></package></packages>
        </coverage>
      XML

      result = described_class.new(xml, workspace: "/srv").parse

      expect(result[:files].keys).to eq(["app/models/user.rb"])
    end

    it "returns empty files hash for blank input" do
      expect(described_class.new("").parse).to eq(files: {})
      expect(described_class.new(nil).parse).to eq(files: {})
    end

    it "returns empty files hash for malformed XML" do
      expect(described_class.new("<not valid xml <<>>").parse).to eq(files: {})
    end

    it "skips class nodes with no filename attribute" do
      xml = <<~XML
        <?xml version="1.0" ?>
        <coverage>
          <packages><package><classes>
            <class>
              <lines><line number="1" hits="1"/></lines>
            </class>
          </classes></package></packages>
        </coverage>
      XML

      result = described_class.new(xml).parse
      expect(result[:files]).to be_empty
    end
  end
end
