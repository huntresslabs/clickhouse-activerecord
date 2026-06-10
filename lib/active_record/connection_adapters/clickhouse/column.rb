module ActiveRecord
  module ConnectionAdapters
    module Clickhouse
      class Column < ActiveRecord::ConnectionAdapters::Column
        attr_reader :codec

        def initialize(*, codec: nil, materialized: false, **)
          super
          @codec = codec
          @materialized = materialized
        end

        # True when the column's expression is a MATERIALIZED expression (as
        # opposed to a plain DEFAULT). The expression itself is carried in
        # +default_function+; this flag records which kind it is so the schema
        # dumper can round-trip it as MATERIALIZED rather than DEFAULT.
        def materialized?
          @materialized
        end

        def ==(other)
          other.is_a?(ActiveRecord::ConnectionAdapters::Clickhouse::Column) &&
            super &&
            codec == other.codec &&
            materialized? == other.materialized?
        end
        alias eql? ==

        private

        def deduplicated
          self
        end
      end
    end
  end
end
