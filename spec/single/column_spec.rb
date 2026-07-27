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

    it 'is false when the default_kind does not match' do
      a = described_class.new(*column_args('created_at', nil, type_metadata, false, 'now()'), default_kind: 'MATERIALIZED')
      b = described_class.new(*column_args('created_at', nil, type_metadata, false, 'now()'), default_kind: 'DEFAULT')

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
      column = described_class.new(*column_args('col', nil, type_metadata, false, 'now()'), default_kind: 'MATERIALIZED')
      expect(column.materialized?).to be(true)
    end
  end
end
