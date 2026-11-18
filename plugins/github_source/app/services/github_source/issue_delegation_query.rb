module GithubSource
  class IssueDelegationQuery
    ADAPTERS = {
      "Mysql2" => "GithubSource::IssueDelegationQuery::Mysql",
      "Trilogy" => "GithubSource::IssueDelegationQuery::Mysql",
      "SQLite" => "GithubSource::IssueDelegationQuery::Sqlite"
    }.freeze

    def self.for(connection)
      ADAPTERS.fetch(connection.adapter_name).constantize.new
    end

    def condition(trigger_label)
      [ sql, trigger_label ]
    end

    private

    def sql = raise NotImplementedError

    class Mysql < self
      private

      def sql
        "JSON_CONTAINS(labels, JSON_OBJECT('name', ?))"
      end
    end

    class Sqlite < self
      private

      def sql
        "EXISTS (SELECT 1 FROM json_each(labels) WHERE json_extract(json_each.value, '$.name') = ?)"
      end
    end
  end
end
