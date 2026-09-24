require "rails_helper"

RSpec.describe "search LIKE escape SQL" do
  it "uses an adapter-quoted escape literal in Job.search's MySQL number branch" do
    allow(Job.connection).to receive(:adapter_name).and_return("Mysql2")
    allow(Job.connection).to receive(:quote).and_call_original
    allow(Job.connection).to receive(:quote).with("\\").and_return("'\\\\'")

    sql = Job.search("Investigate").to_sql

    expect(sql).to include("CAST(issue_number AS CHAR) LIKE")
    expect(sql).to include("ESCAPE '\\\\'")
  end

  it "uses an adapter-quoted escape literal in Epic.search's LIKE fallback" do
    allow(Epic.connection).to receive(:quote).and_call_original
    allow(Epic.connection).to receive(:quote).with("\\").and_return("'\\\\'")

    sql = Epic.search("deploy").to_sql

    expect(sql).to include("title LIKE")
    expect(sql).to include("ESCAPE '\\\\'")
  end

  it "uses an adapter-quoted escape literal in User.search's LIKE fallback" do
    allow(User.connection).to receive(:quote).and_call_original
    allow(User.connection).to receive(:quote).with("\\").and_return("'\\\\'")

    sql = User.search("Grace").to_sql

    expect(sql).to include("email_address LIKE")
    expect(sql).to include("ESCAPE '\\\\'")
  end

  it "uses an adapter-quoted escape literal in PluginRecord.search's LIKE fallback" do
    allow(PluginRecord.connection).to receive(:quote).and_call_original
    allow(PluginRecord.connection).to receive(:quote).with("\\").and_return("'\\\\'")

    sql = PluginRecord.search("storms").to_sql

    expect(sql).to include("description LIKE")
    expect(sql).to include("ESCAPE '\\\\'")
  end
end
