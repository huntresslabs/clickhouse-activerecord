# frozen_string_literal: true

require_relative '../../lib/active_record/connection_adapters/clickhouse/schema_creation'

RSpec.describe ActiveRecord::ConnectionAdapters::Clickhouse::SchemaCreation do
  let(:connection) { double('connection') }
  let(:schema_creation) { described_class.new(connection) }

  describe '#assign_database_to_subquery!' do
    before do
      allow(schema_creation).to receive(:current_database).and_return('test_db')
    end

    context 'when subquery contains a direct table reference' do
      it 'adds database prefix to table name without existing database' do
        subquery = +'select * from users'
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq('select * from test_db.users')
      end

      it 'does not modify table name that already has database prefix' do
        subquery = +'select * from mydb.users'
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq('select * from mydb.users')
      end

      it 'handles table names with dots' do
        subquery = +'select * from schema.table_name'
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq('select * from schema.table_name')
      end

      it 'handles case insensitive FROM keyword' do
        subquery = +'SELECT * FROM users'
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq('SELECT * FROM test_db.users')
      end
    end

    context 'when subquery contains a subquery in FROM clause' do
      it 'does not modify subquery with parentheses after FROM' do
        subquery = 'select * from (select id from users)'
        original_subquery = subquery.dup
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq(original_subquery)
      end

      it 'handles subquery with whitespace before parentheses' do
        subquery = 'select * from   (select id from users where active = true)'
        original_subquery = subquery.dup
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq(original_subquery)
      end

      it 'handles complex nested subqueries' do
        subquery = 'select * from (select u.id, p.name from users u join profiles p on u.id = p.user_id)'
        original_subquery = subquery.dup
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq(original_subquery)
      end

      it 'handles case insensitive FROM with subqueries' do
        subquery = 'SELECT * FROM (SELECT id FROM users)'
        original_subquery = subquery.dup
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq(original_subquery)
      end
    end

    context 'when subquery is nil or empty' do
      it 'returns early for nil subquery' do
        expect { schema_creation.send(:assign_database_to_subquery!, nil) }.not_to raise_error
      end

      it 'returns early for empty subquery' do
        subquery = ''
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq('')
      end
    end

    context 'when subquery does not contain FROM clause' do
      it 'does not modify subquery without FROM' do
        subquery = 'select 1 as id'
        original_subquery = subquery.dup
        schema_creation.send(:assign_database_to_subquery!, subquery)
        expect(subquery).to eq(original_subquery)
      end
    end
  end
end
