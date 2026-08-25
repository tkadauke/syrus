module MysqlDbBrowser
  # Backtick-quotes a MySQL identifier, doubling any embedded backtick so a
  # name interpolated into SQL (even one derived from caller-supplied input)
  # can never break out of identifier position. Supports one dotted
  # qualifier (`table.column`) by quoting each segment independently -
  # shared by FilterTreeSqlCompiler, QueryBuilderCompiler, and the content
  # endpoint's raw SELECT builder so identifier quoting stays in one place.
  module SqlIdentifier
    def self.quote(name)
      name.to_s.split(".", -1).map { |segment| "`#{segment.gsub('`', '``')}`" }.join(".")
    end
  end
end
