require "rails_helper"

RSpec.describe LocalBackups::MysqlSnapshot do
  class RecordingRunner
    Result = Data.define(:exit_status) do
      def success? = exit_status.zero?
    end

    class << self
      attr_accessor :invocations, :dump_path

      def new(**options)
        self.invocations ||= []
        invocations << options
        allocate
      end
    end

    def capture(stdout_limit:, stderr_limit:)
      Struct.new(:success?, :stdout).new(true, "mysqldump  Ver 8.4.1\n")
    end

    def run
      self.class.dump_path.write("consistent sql")
      Result.new(0)
    end
  end

  let(:connection) do
    instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, select_rows: [],
      select_value: "8.4.1")
  end
  let(:config) { { adapter: "mysql2", host: "mysql.internal", port: 3306, database: "syrus", username: "backup", password: "secret" } }

  before { RecordingRunner.invocations = [] }

  it "creates a compressed consistent dump with version metadata and sanitized arguments" do
    Dir.mktmpdir do |directory|
      raw_path = Pathname.new(directory).join("primary.sql")
      destination = Pathname.new(directory).join("primary.sql.gz")
      RecordingRunner.dump_path = raw_path
      snapshot = described_class.new(connection:, config:, runner: RecordingRunner).create(destination)

      expect(Zlib::GzipReader.open(snapshot.path, &:read)).to eq("consistent sql")
      expect(snapshot.path).to eq(destination)
      dump = RecordingRunner.invocations.find { |call| call[:command].include?("--single-transaction") }
      expect(dump[:command]).not_to include("secret")
      expect(dump[:env]).to eq("MYSQL_PWD" => "secret")
      expect(dump[:display_command]).to include("[database]")
      expect(snapshot).to have_attributes(client_version: include("8.4.1"), server_version: "8.4.1")
    end
  end

  it "rejects non-InnoDB tables before invoking mysqldump" do
    allow(connection).to receive(:select_rows).and_return([["legacy", "MyISAM"]])

    expect { described_class.new(connection:, config:, runner: RecordingRunner).create(Pathname.new("unused.sql")) }
      .to raise_error(described_class::UnsupportedEngine, /legacy=MyISAM/)
    expect(RecordingRunner.invocations).to be_empty
  end

  it "selects live blobs in id order with the object export attributes" do
    earlier = ActiveStorage::Blob.create!(
      key: "earlier-key", filename: "earlier.txt", byte_size: 7,
      content_type: "text/plain", checksum: "earlier-checksum"
    )
    later = ActiveStorage::Blob.create!(
      key: "later-key", filename: "later.txt", byte_size: 12,
      content_type: "text/plain", checksum: "later-checksum"
    )

    selection = described_class.new(connection:, config:, runner: RecordingRunner).select_blobs(nil)

    expect(selection).to include(
      { "id" => earlier.id, "key" => "earlier-key", "byte_size" => 7,
        "content_type" => "text/plain", "checksum" => "earlier-checksum" },
      { "id" => later.id, "key" => "later-key", "byte_size" => 12,
        "content_type" => "text/plain", "checksum" => "later-checksum" }
    )
    expect(selection.map { |blob| blob.fetch("id") }).to eq(selection.pluck("id").sort)
  end
end
