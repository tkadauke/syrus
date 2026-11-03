require "rails_helper"

# Two indexes over the same columns in the same order cost exactly as much to
# maintain as one and serve exactly the same queries. They accumulate quietly:
# a migration adds `[provider, status, observed_at]` under one name, a later
# one adds it again under another, and nothing fails -- every insert into a
# write-heavy table just pays twice.
#
# provider_availability_evidences had thirteen indexes, two of them identical,
# and it is written on every provider interaction.
#
# This guards exact duplicates only. Prefix redundancy (`[a]` alongside
# `[a, b]`) is deliberately not flagged: a bare foreign-key-shaped index is
# sometimes kept on purpose, so that call needs a human. Neither is a partial
# or unique index over columns another index already covers -- those are
# different indexes serving different queries.
RSpec.describe "schema indexes" do
  def indexes_by_table
    schema = File.read(Rails.root.join("db/schema.rb"))
    schema.scan(/create_table "([^"]+)".*?\n  end\n/m).flatten.zip(
      schema.scan(/create_table "[^"]+".*?\n  end\n/m)
    ).to_h
  end

  it "has tables to check" do
    expect(indexes_by_table).not_to be_empty
  end

  it "never define the same columns twice on one table" do
    offenders = indexes_by_table.flat_map do |table, body|
      # Compare the whole definition, not just the columns: a partial index
      # (`where:`) or a unique one over the same column is a different index
      # doing a different job, and flagging those would be wrong.
      entries = body.scan(/t\.index (\[[^\]]*\])(.*?), name: "([^"]+)"(.*)$/)
      by_definition = entries.group_by do |columns, before, _name, after|
        [ columns.gsub(/\s+/, ""), "#{before}#{after}".gsub(/\s+/, "") ]
      end

      by_definition.filter_map do |(columns, _qualifiers), group|
        next if group.length < 2

        "#{table} #{columns} defined #{group.length}x: #{group.map { |entry| entry[2] }.join(', ')}"
      end
    end

    expect(offenders).to be_empty, <<~MESSAGE
      These indexes cover identical columns in identical order, so each one
      after the first is pure write overhead. Drop the duplicates in a
      migration and keep the name the queries were written against.

      #{offenders.join("\n")}
    MESSAGE
  end
end
