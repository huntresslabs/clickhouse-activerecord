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
    let(:cast_type) { ActiveRecord::ConnectionAdapters::Clickhouse::OID::DateTime }

    it 'is true when the codec matches' do
      a = described_class.new('created_at', cast_type, nil, type_metadata, false, nil, codec: 'DoubleDelta, LZ4')
      b = described_class.new('created_at', cast_type, nil, type_metadata, false, nil, codec: 'DoubleDelta, LZ4')

      expect(a == b).to eql(true)
    end

    it 'is false when the codec does not match' do
      a = described_class.new('created_at', cast_type, nil, type_metadata, false, nil, codec: nil)
      b = described_class.new('created_at', cast_type, nil, type_metadata, false, nil, codec: 'DoubleDelta, LZ4')

      expect(a == b).to eql(false)
    end
  end
end
