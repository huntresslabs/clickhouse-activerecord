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

  context 'with materialized views' do
    let(:select) { 'SELECT account_id, toDate(created_at) AS day FROM rt_src' }
    let(:create_block) { dump[/  create_table "rt_mv".*?\n  end/m] }

    before do
      connection.execute('CREATE TABLE rt_src (`account_id` UInt32, `created_at` DateTime) ENGINE = MergeTree ORDER BY account_id')
      connection.execute('CREATE TABLE rt_dst (`account_id` UInt32, `day` Date) ENGINE = MergeTree ORDER BY account_id')
    end

    after { ['rt_mv', '`rt_dep (source)`', 'rt_dep_dst', 'rt_dst', 'rt_src'].each { |table| connection.execute("DROP TABLE IF EXISTS #{table}") } }

    shared_examples 'a lossless refreshable round trip' do |refresh|
      it 'recreates an identical view from its dump' do
        connection.create_table 'rt_mv', view: true, materialized: true, refresh: refresh, to: 'rt_dst', id: false, as: select.dup
        original = connection.show_create_table('rt_mv')

        expect(create_block).to eq(
          %(  create_table "rt_mv", view: true, materialized: true, refresh: #{refresh.inspect}, to: "rt_dst", id: false, as: "#{select}", force: :cascade do |t|\n  end)
        )

        connection.execute('DROP TABLE rt_mv')
        ActiveRecord::Migration.suppress_messages { ActiveRecord::Schema.new.instance_eval(create_block) }

        expect(connection.show_create_table('rt_mv')).to eq(original)
      end
    end

    # Refreshable views are experimental before ClickHouse 24.10; Gem::Version because '24.10'.to_f == 24.1
    if Gem::Version.new(ActiveRecord::Base.connection.server_version) >= Gem::Version.new('24.10')
      context 'when refreshable with APPEND' do
        it_behaves_like 'a lossless refreshable round trip', 'EVERY 1 DAY OFFSET 8 HOUR APPEND'
      end

      context 'when refreshable without APPEND' do
        it_behaves_like 'a lossless refreshable round trip', 'EVERY 1 DAY OFFSET 8 HOUR'
      end

      context 'when refreshable with a quoted DEPENDS ON name' do
        before do
          connection.execute('CREATE TABLE rt_dep_dst (`account_id` UInt32, `day` Date) ENGINE = MergeTree ORDER BY account_id')
          connection.execute("CREATE MATERIALIZED VIEW `rt_dep (source)` REFRESH EVERY 1 DAY TO rt_dep_dst AS #{select}")
        end

        it_behaves_like 'a lossless refreshable round trip', 'EVERY 1 DAY DEPENDS ON `rt_dep (source)`'
      end
    end

    it 'dumps a non-refreshable TO view unchanged' do
      connection.execute("CREATE MATERIALIZED VIEW rt_mv TO rt_dst AS #{select}")

      expect(create_block).to eq(
        %(  create_table "rt_mv", view: true, materialized: true, to: "rt_dst", id: false, as: "#{select}", force: :cascade do |t|\n  end)
      )
    end

    it 'dumps a standalone view unchanged' do
      connection.execute("CREATE MATERIALIZED VIEW rt_mv ENGINE = MergeTree ORDER BY account_id AS #{select}")

      expect(create_block).to eq(
        %(  create_table "rt_mv", view: true, materialized: true, id: false, options: "MergeTree ORDER BY account_id SETTINGS index_granularity = 8192", as: "#{select}", force: :cascade do |t|\n  end)
      )
    end
  end
end
