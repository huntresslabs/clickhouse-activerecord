# frozen_string_literal: true

require 'active_record/connection_adapters/clickhouse/column'

RSpec.describe ActiveRecord::ConnectionAdapters::Clickhouse::Column do
  describe '#==' do
    let(:type_metadata) do
      instance_double(
        ActiveRecord::ConnectionAdapters::SqlTypeMetadata,
        sql_type: 'DateTime64(3)',
        type: :timestamp,
        limit: nil,
        precision: 3,
        scale: nil
      )
    end

    # Rails 8.1 added cast_type as the second positional argument to Column#initialize.
    # Build the argument list the same way the production code does (schema_statements.rb).
    let(:cast_type) { double('cast_type', mutable?: false, deserialize: nil) }
    def column_args(name, default, type_meta, null, default_fn)
      args = [name]
      args << cast_type if ActiveRecord.version >= Gem::Version.new('8.1')
      args += [default, type_meta, null, default_fn]
      args
    end

    it 'is true when the codec matches' do
      a = described_class.new(*column_args('created_at', nil, type_metadata, false, nil), codec: 'DoubleDelta, LZ4')
      b = described_class.new(*column_args('created_at', nil, type_metadata, false, nil), codec: 'DoubleDelta, LZ4')

      expect(a == b).to eql(true)
    end

    it 'is false when the codec does not match' do
      a = described_class.new(*column_args('created_at', nil, type_metadata, false, nil), codec: nil)
      b = described_class.new(*column_args('created_at', nil, type_metadata, false, nil), codec: 'DoubleDelta, LZ4')

      expect(a == b).to eql(false)
    end

    it 'is false when the materialized flag does not match' do
      a = described_class.new(*column_args('created_at', nil, type_metadata, false, 'now()'), materialized: true)
      b = described_class.new(*column_args('created_at', nil, type_metadata, false, 'now()'), materialized: false)

      expect(a == b).to eql(false)
    end
  end

  describe '#materialized?' do
    let(:type_metadata) do
      instance_double(
        ActiveRecord::ConnectionAdapters::SqlTypeMetadata,
        sql_type: 'String', type: :string, limit: nil, precision: nil, scale: nil
      )
    end
    let(:cast_type) { double('cast_type', mutable?: false, deserialize: nil) }
    def column_args(name, default, type_meta, null, default_fn)
      args = [name]
      args << cast_type if ActiveRecord.version >= Gem::Version.new('8.1')
      args += [default, type_meta, null, default_fn]
      args
    end

    it 'defaults to false' do
      column = described_class.new(*column_args('col', nil, type_metadata, false, nil))
      expect(column.materialized?).to be(false)
    end

    it 'is true when constructed as materialized' do
      column = described_class.new(*column_args('col', nil, type_metadata, false, 'now()'), materialized: true)
      expect(column.materialized?).to be(true)
    end
  end

  describe '#array' do
    let(:connection) { ActiveRecord::Base.connection }

    before do
      connection.execute(<<~SQL)
        CREATE TABLE array_test (
          `plain` String,
          `count` UInt64,
          `nullable` Nullable(String),
          `low_card` LowCardinality(String),
          `tags` Array(LowCardinality(String)),
          `ids` Array(UInt64),
          `flags` Array(Bool),
          `nested_array` Array(Array(String)),
          `items` Nested(`name` String, `controls` Array(String)),
          `uniq_ids` SimpleAggregateFunction(groupUniqArrayArray, Array(UInt64)),
          `group_state` AggregateFunction(groupArray, String),
          `attrs` Map(String, Array(String))
        ) ENGINE = MergeTree ORDER BY tuple()
      SQL
    end

    after { connection.execute('DROP TABLE IF EXISTS array_test') }

    it 'is true for Array columns, Nested sub-columns and simple aggregates over arrays, and false otherwise' do
      arrays = connection.columns('array_test').to_h { [it.name, [it.array, it.array?]] }

      expect(arrays).to eq(
        'plain' => [false, false],
        'count' => [false, false],
        'nullable' => [false, false],
        'low_card' => [false, false],
        'tags' => [true, true],
        'ids' => [true, true],
        'flags' => [true, true],
        'nested_array' => [true, true],
        'items.name' => [true, true],
        'items.controls' => [true, true],
        'uniq_ids' => [true, true],
        'group_state' => [false, false],
        'attrs' => [false, false]
      )
    end
  end
end
