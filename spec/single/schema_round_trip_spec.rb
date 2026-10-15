# frozen_string_literal: true

require 'spec_helper'
require 'clickhouse-activerecord/schema_dumper'

RSpec.describe 'Schema dump round-trip' do
  let(:connection) { ActiveRecord::Base.connection }
  let(:dump) do
    io = StringIO.new
    ClickhouseActiverecord::SchemaDumper.dump(connection, io)
    io.string
  end

  after { connection.execute('DROP TABLE IF EXISTS rt_test') }

  shared_examples 'a lossless round trip' do
    it 'recreates an identical table from its dump' do
      connection.execute(ddl)
      original = connection.show_create_table('rt_test')
      create_block = dump[/  create_table "rt_test".*?\n  end/m]

      connection.execute('DROP TABLE rt_test')
      ActiveRecord::Migration.suppress_messages { ActiveRecord::Schema.new.instance_eval(create_block) }

      expect(connection.show_create_table('rt_test')).to eq(original)
    end
  end

  context 'with dotted (Nested) column names' do
    let(:ddl) { 'CREATE TABLE rt_test (`members.path` Array(String), `members.offset` Array(UInt64)) ENGINE = MergeTree ORDER BY tuple()' }

    it_behaves_like 'a lossless round trip'
  end

  context 'with sized integer arrays' do
    let(:ddl) { 'CREATE TABLE rt_test (`a` Array(UInt64), `b` Array(UInt8), `c` Array(Int64)) ENGINE = MergeTree ORDER BY tuple()' }

    it_behaves_like 'a lossless round trip'
  end

  context 'with signed integers of every width' do
    let(:ddl) { 'CREATE TABLE rt_test (`a` Int8, `b` Int16, `c` Int32, `d` Int64, `e` Nullable(Int32)) ENGINE = MergeTree ORDER BY tuple()' }

    it_behaves_like 'a lossless round trip'
  end

  context 'with Bool columns' do
    let(:ddl) { 'CREATE TABLE rt_test (`a` Bool, `b` Array(Bool), `c` Array(Nullable(Bool))) ENGINE = MergeTree ORDER BY tuple()' }

    it_behaves_like 'a lossless round trip'
  end

  context 'with nested arrays' do
    let(:ddl) { 'CREATE TABLE rt_test (`a` Array(Array(String)), `b` Array(Array(UInt64))) ENGINE = MergeTree ORDER BY tuple()' }

    it_behaves_like 'a lossless round trip'
  end

  context 'with aggregate functions whose name contains Array' do
    let(:ddl) do
      'CREATE TABLE rt_test (`a` AggregateFunction(groupArray(10), Array(String)), `b` AggregateFunction(groupArray, String)) ' \
        'ENGINE = AggregatingMergeTree ORDER BY tuple()'
    end

    it_behaves_like 'a lossless round trip'
  end

  context 'with a Nested column of mixed sub-column types' do
    let(:ddl) do
      'CREATE TABLE rt_test (`id` String, `items` Nested(`name` String, `kind` LowCardinality(String), `tags` Array(String), `ok` Bool), ' \
        "`at` DateTime64(3, 'UTC')) ENGINE = MergeTree ORDER BY id"
    end

    it_behaves_like 'a lossless round trip'
  end

  context 'with an id column that leads the sorting key' do
    let(:ddl) { 'CREATE TABLE rt_test (`id` String, `name` String) ENGINE = MergeTree ORDER BY id' }

    it_behaves_like 'a lossless round trip'
  end

  context 'with timezone-qualified datetimes' do
    let(:ddl) do
      "CREATE TABLE rt_test (`a` DateTime('UTC'), `b` DateTime64(3, 'UTC'), `c` Nullable(DateTime('America/New_York')), `d` DateTime64(6)) " \
        'ENGINE = MergeTree ORDER BY tuple()'
    end

    it_behaves_like 'a lossless round trip'
  end

  context 'with a Merge engine over the current database' do
    let(:ddl) { "CREATE TABLE rt_test (`id` UInt64) ENGINE = Merge('#{connection.database}', '^rt_source$')" }

    it_behaves_like 'a lossless round trip'

    it 'dumps the database name as a connection-relative token' do
      connection.execute(ddl)

      expect(dump.lines.grep(/rt_test/).join).not_to include("'#{connection.database}'")
    end
  end
end
