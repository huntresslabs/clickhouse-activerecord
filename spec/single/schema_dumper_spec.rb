# frozen_string_literal: true

require 'clickhouse-activerecord/schema_dumper'

RSpec.describe ClickhouseActiverecord::SchemaDumper, :migrations do
  let(:directory) { raise 'NotImplemented' }
  let(:migrations_dir) { File.join(FIXTURES_PATH, 'migrations', directory) }
  let(:migration_context) { ActiveRecord::MigrationContext.new(migrations_dir) }

  before do
    quietly { migration_context.up }
  end

  subject do
    ClickhouseActiverecord::SchemaDumper.dump
  end

  describe '.dump' do
    context 'aggregate_function' do
      let(:directory) { 'schema_table_with_aggregate_function_creation' }

      it 'dumps AggregateFunction(sum, Float32) using DSL float type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.float "col1", aggregate_function: "sum", limit: 4, null: false/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps AggregateFunction(anyLast, Float64) using DSL float type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.float "col2", aggregate_function: "anyLast", limit: 8, null: false/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps AggregateFunction(anyLast, DateTime64) as t.column with raw SQL type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.column "col3", "AggregateFunction\(anyLast, DateTime64\(3\)\)"/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps SimpleAggregateFunction as t.column with raw SQL type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.column "col4", "SimpleAggregateFunction\(anyLast, DateTime64\(3\)\)"/)
          end
        ).to_stdout_from_any_process
      end
    end

    context 'summing_merge_tree with aggregate function columns' do
      let(:directory) { 'schema_table_with_summing_merge_tree_aggregate_function' }

      subject do
        allow_any_instance_of(ActiveRecord::ConnectionAdapters::ClickhouseAdapter)
          .to receive(:table_options)
          .and_return({ options: +'SummingMergeTree() ORDER BY (date)' })

        ClickhouseActiverecord::SchemaDumper.dump
      end

      it 'dumps AggregateFunction columns using DSL float type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.float "col1", aggregate_function: "sum", limit: 8, null: false/)
            expect(schema).to match(/t\.float "col2", aggregate_function: "anyLast", limit: 8, null: false/)
          end
        ).to_stdout_from_any_process
      end
    end

    context 'fixed_string' do
      let(:directory) { 'dsl_table_with_fixed_string_creation' }

      it 'dumps plain FixedString with fixed_string option' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.string "fixed_string1", fixed_string: 1, null: false/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps FixedString array with fixed_string option' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.string "fixed_string16_array", array: true, fixed_string: 16/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps FixedString map with fixed_string option' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.string "fixed_string16_map", map: true, fixed_string: 16/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps FixedString map array with fixed_string option' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.string "fixed_string16_map_array", array: true, map: true, fixed_string: 16/)
          end
        ).to_stdout_from_any_process
      end
    end

    context 'aggregating_merge_tree preserves aggregate function columns' do
      let(:directory) { 'schema_table_with_summing_merge_tree_aggregate_function' }

      it 'dumps AggregateFunction columns using DSL float type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.float "col1", aggregate_function: "sum", limit: 8, null: false/)
            expect(schema).to match(/t\.float "col2", aggregate_function: "anyLast", limit: 8, null: false/)
          end
        ).to_stdout_from_any_process
      end
    end

    context 'projection' do
      let(:directory) { 'dsl_create_table_with_projection' }

      it 'dumps t.projection entries for each table projection' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.projection "proj_by_int1", "SELECT \* ORDER BY int1, int2"/)
            expect(schema).to match(/t\.projection "proj_by_int2", "SELECT \* ORDER BY int2, int1"/)
          end
        ).to_stdout_from_any_process
      end

      it 'creates the projections in ClickHouse so the SQL comment includes them' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to include('PROJECTION proj_by_int1')
            expect(schema).to include('PROJECTION proj_by_int2')
          end
        ).to_stdout_from_any_process
      end
    end
  end

end

RSpec.describe ClickhouseActiverecord::SchemaDumper, '#parse_projections' do
  let(:dumper) { ClickhouseActiverecord::SchemaDumper.send(:allocate) }

  it 'extracts a simple projection' do
    sql = "CREATE TABLE t ( `id` UInt64, PROJECTION p1 ( SELECT * ORDER BY id ) ) ENGINE = MergeTree"
    expect(dumper.send(:parse_projections, sql)).to eq([['p1', 'SELECT * ORDER BY id']])
  end

  it 'extracts multiple projections' do
    sql = "CREATE TABLE t ( `id` UInt64, " \
          "PROJECTION p1 ( SELECT * ORDER BY id ), " \
          "PROJECTION p2 ( SELECT * ORDER BY id, id ) ) ENGINE = MergeTree"
    expect(dumper.send(:parse_projections, sql)).to eq([
      ['p1', 'SELECT * ORDER BY id'],
      ['p2', 'SELECT * ORDER BY id, id']
    ])
  end

  it 'handles parentheses inside the projection body' do
    sql = "CREATE TABLE t ( `x` String, PROJECTION p_count ( SELECT count(*), x ORDER BY x ) ) ENGINE = MergeTree"
    expect(dumper.send(:parse_projections, sql)).to eq([
      ['p_count', 'SELECT count(*), x ORDER BY x']
    ])
  end

  it 'ignores parens inside single-quoted string literals' do
    sql = "CREATE TABLE t ( `label` String, PROJECTION p_str ( SELECT * WHERE label = '(' ORDER BY label ) ) ENGINE = MergeTree"
    expect(dumper.send(:parse_projections, sql)).to eq([
      ['p_str', "SELECT * WHERE label = '(' ORDER BY label"]
    ])
  end

  it 'handles backslash-escaped quotes inside string literals' do
    sql = "CREATE TABLE t ( `label` String, PROJECTION p_esc ( SELECT * WHERE label = 'it\\'s (open' ORDER BY label ) ) ENGINE = MergeTree"
    expect(dumper.send(:parse_projections, sql)).to eq([
      ['p_esc', "SELECT * WHERE label = 'it\\'s (open' ORDER BY label"]
    ])
  end

  it 'strips backticks from projection names' do
    sql = "CREATE TABLE t ( `id` UInt64, PROJECTION `weird-name` ( SELECT * ORDER BY id ) ) ENGINE = MergeTree"
    expect(dumper.send(:parse_projections, sql)).to eq([
      ['weird-name', 'SELECT * ORDER BY id']
    ])
  end
end
