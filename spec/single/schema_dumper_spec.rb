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
            expect(schema).to match(/t\.string "fixed_string16_array", fixed_string: 16, array: true/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps FixedString map with fixed_string option' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.string "fixed_string16_map", fixed_string: 16, map: true/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps FixedString map array with fixed_string option' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.string "fixed_string16_map_array", fixed_string: 16, map: :array/)
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
  end
end
