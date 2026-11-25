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

  context 'with dictionaries' do
    before do
      connection.execute('CREATE TABLE rt_src (`id` UInt64, `name` String) ENGINE = MergeTree ORDER BY id')
      connection.execute(<<~SQL.squish)
        CREATE DICTIONARY rt_dict (`id` UInt64, `name` String)
        PRIMARY KEY id
        SOURCE(CLICKHOUSE(TABLE 'rt_src'))
        LAYOUT(HASHED())
        LIFETIME(MIN 0 MAX 3600)
      SQL
    end

    after do
      connection.execute('DROP DICTIONARY IF EXISTS rt_dict')
      connection.execute('DROP TABLE IF EXISTS rt_src')
    end

    it 'recreates an identical dictionary from its dump' do
      original = connection.show_create_table('rt_dict')
      create_line = dump[/^  create_dictionary "rt_dict", .*$/]

      connection.execute('DROP DICTIONARY rt_dict')
      ActiveRecord::Migration.suppress_messages { ActiveRecord::Schema.new.instance_eval(create_line) }

      expect(connection.show_create_table('rt_dict')).to eq(original)
    end

    it 'does not dump a dictionary as a table' do
      expect(dump.lines.grep(/create_table "rt_dict"|# TABLE: rt_dict$/)).to be_empty
    end

    it 'loads its dump over a database that still has the dictionary and its source table' do
      original = connection.show_create_table('rt_dict')

      ActiveRecord::Migration.suppress_messages { eval(dump) } # rubocop:disable Security/Eval

      expect(connection.show_create_table('rt_dict')).to eq(original)
    end

    context 'when the dictionary name needs quoting' do
      before do
        connection.execute(<<~SQL.squish)
          CREATE DICTIONARY `rt dict` (`id` UInt64, `name` String)
          PRIMARY KEY id
          SOURCE(CLICKHOUSE(TABLE 'rt_src'))
          LAYOUT(HASHED())
          LIFETIME(MIN 0 MAX 3600)
        SQL
      end

      after { connection.execute('DROP DICTIONARY IF EXISTS `rt dict`') }

      it 'loads its dump over a database that still has the dictionary' do
        original = connection.show_create_table('rt dict')

        ActiveRecord::Migration.suppress_messages { eval(dump) } # rubocop:disable Security/Eval

        expect(connection.show_create_table('rt dict')).to eq(original)
      end
    end

    context 'when a view reads the dictionary' do
      before { connection.execute('CREATE VIEW rt_dict_view AS SELECT id, name FROM rt_dict') }

      after { connection.execute('DROP VIEW IF EXISTS rt_dict_view') }

      it 'loads its dump into an empty database' do
        original = connection.show_create_table('rt_dict_view')
        schema = dump
        connection.execute('DROP VIEW rt_dict_view')
        connection.execute('DROP DICTIONARY rt_dict')
        connection.execute('DROP TABLE rt_src')

        ActiveRecord::Migration.suppress_messages { eval(schema) } # rubocop:disable Security/Eval

        expect(connection.show_create_table('rt_dict_view')).to eq(original)
      end
    end
  end
end
