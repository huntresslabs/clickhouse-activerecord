# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveRecord::ConnectionAdapters::Clickhouse::OID::Map do
  subject(:map) { described_class.new(sql_type) }

  describe '#deserialize' do
    context 'with string key types (Map(String, ...))' do
      context 'Map(String, String)' do
        let(:sql_type) { 'Map(String, String)' }

        it 'returns string values unchanged' do
          expect(map.deserialize({'a' => 'hello', 'b' => 'world'})).to eq({'a' => 'hello', 'b' => 'world'})
        end
      end

      context 'Map(String, Int32)' do
        let(:sql_type) { 'Map(String, Int32)' }

        it 'casts values to integers' do
          expect(map.deserialize({'a' => '1', 'b' => '2'})).to eq({'a' => 1, 'b' => 2})
        end
      end

      context 'Map(String, Array(DateTime))' do
        let(:sql_type) { 'Map(String, Array(DateTime))' }

        it 'casts array values to DateTime' do
          result = map.deserialize({'a' => ['2022-01-01 00:00:00']})
          expect(result['a'].first).to be_a(DateTime)
        end
      end

      context 'Map(String, Array(String))' do
        let(:sql_type) { 'Map(String, Array(String))' }

        it 'returns string array values unchanged' do
          expect(map.deserialize({'a' => ['str1', 'str2']})).to eq({'a' => ['str1', 'str2']})
        end
      end
    end

    context 'with integer key types (previously buggy)' do
      context 'Map(Int32, String)' do
        let(:sql_type) { 'Map(Int32, String)' }

        it 'does not cast string values to integers' do
          expect(map.deserialize({'1' => 'hello', '2' => 'world'})).to eq({'1' => 'hello', '2' => 'world'})
        end
      end

      context 'Map(UInt32, String)' do
        let(:sql_type) { 'Map(UInt32, String)' }

        it 'does not cast string values to integers' do
          expect(map.deserialize({'1' => 'foo', '2' => 'bar'})).to eq({'1' => 'foo', '2' => 'bar'})
        end
      end

      context 'Map(UInt32, Array(String))' do
        let(:sql_type) { 'Map(UInt32, Array(String))' }

        it 'does not cast string array values to integers' do
          expect(map.deserialize({'1' => ['a', 'b'], '2' => ['c']})).to eq({'1' => ['a', 'b'], '2' => ['c']})
        end
      end

      context 'Map(Int32, Array(Array(String)))' do
        let(:sql_type) { 'Map(Int32, Array(Array(String)))' }

        it 'does not cast nested string array values to integers' do
          input = {'1' => [['foo', 'bar'], ['baz']], '2' => [['qux']]}
          expect(map.deserialize(input)).to eq({'1' => [['foo', 'bar'], ['baz']], '2' => [['qux']]})
        end
      end

      context 'Map(Int64, Int32)' do
        let(:sql_type) { 'Map(Int64, Int32)' }

        it 'casts values (not keys) to integers' do
          expect(map.deserialize({'1' => '42', '2' => '7'})).to eq({'1' => 42, '2' => 7})
        end
      end
    end
  end
end
