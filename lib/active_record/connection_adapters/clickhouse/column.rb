module ActiveRecord
  module ConnectionAdapters
    module Clickhouse
      DescribedColumn =
        Data.define(:name, :sql_type, :default_type, :default_expression, :comment, :codec) do
          def ephemeral?
            default_type.to_s.downcase == 'ephemeral'
          end
        end

      class Column < ActiveRecord::ConnectionAdapters::Column
        attr_reader :codec, :default_kind

        def initialize(*, codec: nil, default_kind: nil, **)
          super
          @codec = codec
          @default_kind = ActiveSupport::StringInquirer.new(default_kind.to_s.downcase.presence || 'none')
        end

        # True when the column is a virtual (computed) column that must be
        # excluded from INSERT statements: MATERIALIZED and ALIAS columns.
        def virtual?
          default_kind.materialized? || default_kind.alias?
        end

        # True when the column's expression is a MATERIALIZED expression (as
        # opposed to a plain DEFAULT). The expression itself is carried in
        # +default_function+; this flag records which kind it is so the schema
        # dumper can round-trip it as MATERIALIZED rather than DEFAULT.
        def materialized?
          default_kind.materialized?
        end

        def ==(other)
          other.is_a?(ActiveRecord::ConnectionAdapters::Clickhouse::Column) &&
            super &&
            codec == other.codec &&
            default_kind == other.default_kind
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
