# frozen_string_literal: true

require 'spec_helper'
require 'clickhouse-activerecord/schema_dumper'

RSpec.describe 'MATERIALIZED column support' do
  let(:connection) { ActiveRecord::Base.connection }

  # A column with both a codec and an expression. Before the ordering fix this
  # produced invalid DDL (`<type> CODEC(...) DEFAULT/MATERIALIZED <expr>`), which
  # failed on creation and made the dumped schema unloadable. The column type is
  # incidental (String, to stay portable across ClickHouse versions); what matters
  # is that it has both a CODEC and a MATERIALIZED expression.
  def create_mat_test
    connection.create_table('mat_test', id: false, options: 'MergeTree ORDER BY tuple()') do |t|
      t.integer :flag, limit: 1, null: false, default: 0
      t.string :body, null: false, default: ''
      t.string :doc, codec: 'ZSTD(3)', null: false,
                   materialized: -> { "if(flag = 1, upper(body), '')" }
    end
  end

  after do
    connection.execute('DROP TABLE IF EXISTS mat_test')
  end

  describe 'DDL generation (expression precedes CODEC)' do
    it 'emits MATERIALIZED before CODEC' do
      create_mat_test
      ddl = connection.show_create_table('mat_test')
      expect(ddl).to match(/`doc` String MATERIALIZED .+ CODEC\(ZSTD\(3\)\)/)
    end

    it 'emits a plain DEFAULT before CODEC' do
      connection.create_table('mat_test', id: false, options: 'MergeTree ORDER BY tuple()') do |t|
        t.integer :id, limit: 8, null: false
        t.string :name, codec: 'ZSTD(3)', null: false, default: -> { 'toString(id)' }
      end
      ddl = connection.show_create_table('mat_test')
      expect(ddl).to match(/`name` String DEFAULT toString\(id\) CODEC\(ZSTD\(3\)\)/)
    end
  end

  describe 'introspection' do
    before { create_mat_test }

    it 'flags a MATERIALIZED column as materialized and keeps its expression' do
      doc = connection.columns('mat_test').find { |c| c.name == 'doc' }
      expect(doc.materialized?).to be(true)
      expect(doc.default_function).to include('upper(body)')
    end

    it 'does not flag a plain DEFAULT column as materialized' do
      flag = connection.columns('mat_test').find { |c| c.name == 'flag' }
      expect(flag.materialized?).to be(false)
    end
  end

  describe 'schema dump' do
    before { create_mat_test }

    subject(:dump) do
      io = StringIO.new
      ClickhouseActiverecord::SchemaDumper.dump(connection, io)
      io.string
    end

    it 'dumps the column as materialized: with its codec, not as default:' do
      doc_line = dump.lines.find { |l| l.include?('"doc"') }
      expect(doc_line).to include('codec: "ZSTD(3)"')
      expect(doc_line).to include(%(materialized: -> { "if(flag = 1, upper(body), '')" }))
      expect(doc_line).not_to include('default:')
    end
  end

  describe 'schema dump round-trip' do
    before { create_mat_test }

    it 'reloads the dumped table definition and preserves the MATERIALIZED column' do
      io = StringIO.new
      ClickhouseActiverecord::SchemaDumper.dump(connection, io)
      create_block = io.string[/create_table "mat_test".*?\n  end/m]
      expect(create_block).not_to be_nil

      connection.execute('DROP TABLE IF EXISTS mat_test')

      # Re-running the dumped create_table must not raise. Before the fix the
      # regenerated DDL placed CODEC before the expression, which ClickHouse
      # rejects. Eval against the connection so create_table/t.json resolve.
      expect { connection.instance_eval(create_block) }.not_to raise_error

      reloaded = connection.columns('mat_test').find { |c| c.name == 'doc' }
      expect(reloaded.materialized?).to be(true)
    end
  end

  describe 'expression shapes' do
    it 'round-trips a non-function-shaped MATERIALIZED expression' do
      # `flag + 1` is not function-shaped, so extract_default_function would miss
      # it; the expression must still survive the dump as materialized:.
      connection.create_table('mat_test', id: false, options: 'MergeTree ORDER BY tuple()') do |t|
        t.integer :flag, limit: 1, null: false, default: 0
        t.integer :flag_plus_one, limit: 2, null: false, materialized: -> { 'flag + 1' }
      end

      io = StringIO.new
      ClickhouseActiverecord::SchemaDumper.dump(connection, io)
      schema = io.string

      line = schema.lines.find { |l| l.include?('"flag_plus_one"') }
      expect(line).to include('materialized: -> { "flag + 1" }')
      expect(line).not_to include('default:')

      create_block = schema[/create_table "mat_test".*?\n  end/m]
      connection.execute('DROP TABLE IF EXISTS mat_test')
      expect { connection.instance_eval(create_block) }.not_to raise_error
      expect(connection.columns('mat_test').find { |c| c.name == 'flag_plus_one' }.materialized?).to be(true)
    end

    it 'round-trips a MATERIALIZED column without a codec' do
      connection.create_table('mat_test', id: false, options: 'MergeTree ORDER BY tuple()') do |t|
        t.integer :flag, limit: 1, null: false, default: 0
        t.integer :flag_copy, limit: 1, null: false, materialized: -> { 'flag' }
      end

      io = StringIO.new
      ClickhouseActiverecord::SchemaDumper.dump(connection, io)
      schema = io.string
      expect(schema.lines.find { |l| l.include?('"flag_copy"') }).to include('materialized: -> { "flag" }')

      create_block = schema[/create_table "mat_test".*?\n  end/m]
      connection.execute('DROP TABLE IF EXISTS mat_test')
      expect { connection.instance_eval(create_block) }.not_to raise_error
      expect(connection.columns('mat_test').find { |c| c.name == 'flag_copy' }.materialized?).to be(true)
    end
  end
end
