# frozen_string_literal: true

require 'clickhouse-activerecord/schema_dumper'

RSpec.describe 'Cluster schema dump round-trip' do
  let(:connection) { ActiveRecord::Base.connection }
  let(:cluster) { connection.cluster }
  let(:dump) do
    io = StringIO.new
    ClickhouseActiverecord::SchemaDumper.dump(connection, io)
    io.string
  end

  context 'with dictionaries' do
    before do
      connection.execute("CREATE TABLE rt_src ON CLUSTER #{cluster} (`id` UInt64, `name` String) ENGINE = MergeTree ORDER BY id")
      connection.execute(<<~SQL.squish)
        CREATE DICTIONARY rt_dict ON CLUSTER #{cluster} (`id` UInt64, `name` String)
        PRIMARY KEY id
        SOURCE(CLICKHOUSE(TABLE 'rt_src'))
        LAYOUT(HASHED())
        LIFETIME(MIN 0 MAX 3600)
      SQL
    end

    after do
      connection.execute("DROP DICTIONARY IF EXISTS rt_dict ON CLUSTER #{cluster} SYNC")
      connection.execute("DROP TABLE IF EXISTS rt_src ON CLUSTER #{cluster} SYNC")
    end

    it 'loads its dump over a cluster that still has the dictionary and its source table on every node' do
      original = connection.show_create_table('rt_dict')

      ActiveRecord::Migration.suppress_messages { eval(dump) } # rubocop:disable Security/Eval

      expect(connection.show_create_table('rt_dict')).to eq(original)
    end
  end
end
