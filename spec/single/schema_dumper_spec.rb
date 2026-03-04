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

  describe ".dump" do
    context 'aggregate_function' do
      let(:directory) { 'schema_table_with_aggregate_function_creation' }

      it 'dumps AggregateFunction(sum, Float32) as t.column with raw SQL type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.column "col1", "AggregateFunction\(sum, Float32\)"/)
          end
        ).to_stdout_from_any_process
      end

      it 'dumps AggregateFunction(anyLast, Float64) as t.column with raw SQL type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.column "col2", "AggregateFunction\(anyLast, Float64\)"/)
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

      it 'does not include aggregate_function option in colspec' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).not_to match(/aggregate_function:/)
            expect(schema).not_to match(/simple_aggregate_function:/)
          end
        ).to_stdout_from_any_process
      end
    end

    context 'summing_merge_tree with aggregate function columns' do
      let(:directory) { 'schema_table_with_summing_merge_tree_aggregate_function' }

      subject do
        allow_any_instance_of(ActiveRecord::ConnectionAdapters::ClickhouseAdapter)
          .to receive(:table_options)
          .and_return({ options: +"SummingMergeTree() ORDER BY (date)" })

        ClickhouseActiverecord::SchemaDumper.dump
      end

      it 'dumps AggregateFunction columns as t.column with raw SQL type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.column "col1", "AggregateFunction\(sum, Float64\)", null: false/)
            expect(schema).to match(/t\.column "col2", "AggregateFunction\(anyLast, Float64\)", null: false/)
            expect(schema).not_to match(/aggregate_function:/)
          end
        ).to_stdout_from_any_process
      end
    end

    context 'aggregating_merge_tree preserves aggregate function columns' do
      let(:directory) { 'schema_table_with_summing_merge_tree_aggregate_function' }

      it 'dumps AggregateFunction columns as t.column with raw SQL type' do
        expect { subject }.to output(
          satisfy do |schema|
            expect(schema).to match(/t\.column "col1", "AggregateFunction\(sum, Float64\)", null: false/)
            expect(schema).to match(/t\.column "col2", "AggregateFunction\(anyLast, Float64\)", null: false/)
            expect(schema).not_to match(/aggregate_function:/)
          end
        ).to_stdout_from_any_process
      end
    end
  end
end
