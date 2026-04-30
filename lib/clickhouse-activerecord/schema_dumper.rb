module ClickhouseActiverecord
  class SchemaDumper < ::ActiveRecord::ConnectionAdapters::SchemaDumper
    attr_accessor :simple

    class << self
      def dump(connection = ActiveRecord::Base.connection, stream = STDOUT, config = ActiveRecord::Base,
               default = false)
        dumper = connection.create_schema_dumper(generate_options(config))
        dumper.simple = default
        dumper.dump(stream)
        stream
      end
    end

    private

    def tables(stream)
      functions = @connection.functions.sort
      functions.each do |function|
        function(function, stream)
      end

      view_tables = @connection.views.sort
      materialized_view_tables = @connection.materialized_views.sort
      sorted_tables = @connection.tables.sort - view_tables - materialized_view_tables

      (sorted_tables + view_tables + materialized_view_tables).each do |table_name|
        table(table_name, stream) unless ignored?(table_name)
      end
    end

    def table(table, stream)
      return unless table.match(/^\.inner/).nil?

      sql = ''
      simple ||= ENV['simple'] == 'true'
      unless simple
        stream.puts "  # TABLE: #{table}"
        sql = @connection.show_create_table(table)
        if sql
          stream.puts "  # SQL: #{sql.gsub(/ENGINE = Replicated(.*?)\('[^']+',\s*'[^']+',?\s?([^)]*)?\)/,
                                           'ENGINE = \\1(\\2)')}"
        end
        # super(table.gsub(/^\.inner\./, ''), stream)

        # detect view table
        view_match = sql.match(/^CREATE\s+(MATERIALIZED\s+)?VIEW\s+\S+\s+(?:TO (\S+))?/)
      end

      # Copy from original dumper
      columns = @connection.columns(table)
      begin
        tbl = StringIO.new

        # first dump primary key column
        pk = @connection.primary_key(table)

        tbl.print "  create_table #{remove_prefix_and_suffix(table).inspect}"

        unless simple
          # Add materialize flag
          tbl.print ', view: true' if view_match
          tbl.print ', materialized: true' if view_match && view_match[1].presence
          tbl.print ", to: \"#{view_match[2]}\"" if view_match && view_match[2].presence
        end

        if (id = columns.detect { |c| c.name == 'id' })
          spec = column_spec_for_primary_key(id)
          tbl.print ", #{format_colspec(spec)}" if spec.present?
        else
          tbl.print ', id: false'
        end

        unless simple
          table_options = @connection.table_options(table)
          # Suppress the "Log" engine option for materialized views - ClickHouse reports Log
          # as the internal engine for refreshable or standalone materialized views, but it
          # is not a user-specified engine and should not be emitted in the schema.
          table_options.delete(:options) if view_match && table_options&.dig(:options)&.strip == 'Log'
          if table_options.present?
            table_options = format_options(table_options)
            table_options.gsub!(/Buffer\('[^']+'/, 'Buffer(\'#{connection.database}\'')
            tbl.print ", #{table_options}"
          end
        end

        tbl.puts ', force: :cascade do |t|'

        # then dump all non-primary key columns
        if simple || !view_match
          columns.each do |column|
            unless @connection.valid_type?(column.type)
              raise StandardError,
                    "Unknown type '#{column.sql_type}' for column '#{column.name}'"
            end
            next if column.name == pk && column.name == 'id'

            name = column.name =~ /\./ ? "\"`#{column.name}`\"" : column.name.inspect
            if column.sql_type.match?(/^(Simple)?AggregateFunction/)
              dsl_type = aggregate_function_dsl_type(column.sql_type)
              if dsl_type
                _type, colspec = column_spec(column)
                tbl.print "    t.#{dsl_type} #{name}"
                tbl.print ", #{format_colspec(colspec)}" if colspec.present?
              else
                # Complex inner type with no DSL equivalent - use t.column with raw SQL type
                tbl.print "    t.column #{name}, #{column.sql_type.inspect}"
                colspec = prepare_column_options(column).slice(:null, :default, :codec)
                tbl.print ", #{format_colspec(colspec)}" if colspec.present?
              end
            else
              type, colspec = column_spec(column)
              tbl.print "    t.#{type} #{name}"
              tbl.print ", #{format_colspec(colspec)}" if colspec.present?
            end
            tbl.puts
          end
        end

        indexes = sql.scan(/INDEX \S+ \S+ TYPE .*? GRANULARITY \d+/)
        projections = parse_projections(sql)
        if indexes.any? || projections.any?
          tbl.puts ''
          indexes.flatten.map!(&:strip).each do |index|
            tbl.puts "    t.index #{index_parts(index).join(', ')}"
          end
          projections.each do |name, query|
            tbl.puts "    t.projection #{name.inspect}, #{query.inspect}"
          end
        end

        tbl.puts '  end'
        tbl.puts

        tbl.rewind
        stream.print tbl.read
      rescue StandardError => e
        stream.puts "# Could not dump table #{table.inspect} because of following #{e.class}"
        stream.puts "#   #{e.message}"
        stream.puts
      end
    end

    def column_spec_for_primary_key(column)
      spec = super

      id = ActiveRecord::ConnectionAdapters::ClickhouseAdapter::NATIVE_DATABASE_TYPES.invert[{ name: column.sql_type.gsub(
        /\(\d+\)/, ''
      ) }]
      spec[:id] = id.inspect if id.present?

      spec.except!(:limit, :unsigned) # This can be removed at some date, it is only here to clean up existing schemas which have dumped these values already
    end

    def function(function, stream)
      stream.puts "  # FUNCTION: #{function}"
      sql = @connection.show_create_function(function)
      return unless sql

      stream.puts "  # SQL: #{sql}"
      body = sql.sub(/\ACREATE( OR REPLACE)? FUNCTION .*? AS/, '').strip
      stream.puts "  create_function \"#{function}\", \"#{body}\", force: true"
      stream.puts
    end

    def format_options(options)
      if options && options[:options]
        options[:options].gsub!(/^Replicated(.*?)\('[^']+',\s*'[^']+',?\s?([^)]*)?\)/, '\\1(\\2)')
      end
      super
    end

    def format_colspec(colspec)
      if simple
        super.gsub(/CAST\('?([^,']*)'?,\s?'.*?'\)/, '\\1')
      else
        super
      end
    end

    def schema_limit(column)
      if column.type == :float
        inner = aggregate_function_inner_type(column.sql_type) || column.sql_type
        return 4 if inner == 'Float32'

        8 if inner == 'Float64'
      else
        super
      end
    end

    def schema_unsigned(column)
      return nil unless column.type == :integer && !simple

      (column.sql_type =~ /(Nullable)?\(?UInt\d+\)?/).nil? ? false : nil
    end

    def schema_array(column)
      (column.sql_type =~ /Array\(/).nil? ? nil : true
    end

    def schema_map(column)
      return :array if column.sql_type =~ /Map\(([^,]+),\s*(Array)\)/

      (column.sql_type =~ /Map\(/).nil? ? nil : true
    end

    def schema_low_cardinality(column)
      (column.sql_type =~ /LowCardinality\(/).nil? ? nil : true
    end

    def schema_fixed_string(column)
      match = column.sql_type.match(/FixedString\((\d+)\)/)
      match ? match[1].to_i : nil
    end

    def schema_aggregate_function(column)
      parts = parse_aggregate_function(column.sql_type)
      return {} if parts.nil?

      type = parts[:wrapper] == 'AggregateFunction' ? :aggregate_function : :simple_aggregate_function
      { type => parts[:agg_fn].inspect }
    end

    # Returns the DSL column type symbol for an (Simple)AggregateFunction sql_type,
    # based on the inner ClickHouse data type. Returns nil when no DSL equivalent exists.
    def aggregate_function_dsl_type(sql_type)
      parts = parse_aggregate_function(sql_type)
      return nil if parts.nil?

      inner_full = parts[:data_type]

      # Handle Array(X) inner types - map to the element type
      if (array_match = inner_full.match(/\AArray\(([^)]+)\)\z/))
        inner = array_match[1].match(/\A[A-Za-z][A-Za-z0-9]*/)[0]
        return dsl_type_for_inner(inner)
      end

      inner = inner_full.match(/\A([A-Za-z][A-Za-z0-9]*)/)[1]
      dsl_type_for_inner(inner)
    end

    # Maps a ClickHouse base type name to a Rails DSL type symbol, or nil if unmappable.
    # Only plain, parameter-free type names map to DSL types; parameterised types like
    # DateTime64(3) or FixedString(16) have no direct DSL equivalent and return nil.
    def dsl_type_for_inner(inner)
      return :float    if inner.match?(/\AFloat(32|64)\z/)
      return :integer  if inner.match?(/\A(U?Int(8|16|32|64))\z/)
      return :datetime if inner == 'DateTime'
      return :string   if inner == 'String'

      nil
    end

    # Parses an (Simple)AggregateFunction sql_type into its component parts.
    # Returns { wrapper:, agg_fn:, data_type: } or nil if not a recognised pattern.
    #
    # Uses a paren-depth-aware scan to find the last top-level comma, correctly
    # handling parameterised aggregate functions (e.g. topK(10)) and complex inner
    # types that themselves contain commas (e.g. Tuple(Float64, Float64)).
    #
    # Examples:
    #   "AggregateFunction(sum, Float64)"                      => { wrapper: "AggregateFunction",       agg_fn: "sum",      data_type: "Float64" }
    #   "AggregateFunction(topK(10), Tuple(Float64, Float64))" => { wrapper: "AggregateFunction",       agg_fn: "topK(10)", data_type: "Tuple(Float64, Float64)" }
    #   "AggregateFunction(max, DateTime64(3))"                => { wrapper: "AggregateFunction",       agg_fn: "max",      data_type: "DateTime64(3)" }
    #   "SimpleAggregateFunction(sum, Int64)"                  => { wrapper: "SimpleAggregateFunction", agg_fn: "sum",      data_type: "Int64" }
    def parse_aggregate_function(sql_type)
      outer = sql_type.match(/\A((?:Simple)?AggregateFunction)\((.+)\)\z/m)
      return nil if outer.nil?

      wrapper = outer[1]
      inner   = outer[2]

      # Find the last top-level comma (not nested inside parentheses)
      depth      = 0
      last_comma = nil
      inner.chars.each_with_index do |c, i|
        case c
        when '(' then depth += 1
        when ')' then depth -= 1
        when ',' then last_comma = i if depth == 0
        end
      end

      return nil if last_comma.nil?

      {
        wrapper: wrapper,
        agg_fn: inner[0...last_comma].strip,
        data_type: inner[last_comma + 1..].strip
      }
    end

    # Extracts the base inner type name (no parens/suffix) for schema_limit lookups.
    # e.g. "AggregateFunction(sum, Float64)"    => "Float64"
    #      "AggregateFunction(max, DateTime64(3))" => "DateTime64"
    def aggregate_function_inner_type(sql_type)
      parts = parse_aggregate_function(sql_type)
      return nil if parts.nil?

      parts[:data_type].match(/\A([A-Za-z][A-Za-z0-9]*)/)[1]
    end

    # @param [ActiveRecord::ConnectionAdapters::Clickhouse::Column] column
    def prepare_column_options(column)
      spec = {}
      spec[:unsigned] = schema_unsigned(column)
      spec[:array] = schema_array(column)
      spec[:map] = schema_map(column)
      spec[:array] = nil if spec[:map] == :array
      spec[:low_cardinality] = schema_low_cardinality(column)
      spec[:fixed_string] = schema_fixed_string(column)
      spec[:codec] = column.codec.inspect if column.codec
      spec.merge! schema_aggregate_function(column)
      spec.merge(super).compact
    end

    # Extracts projection definitions from a SHOW CREATE TABLE statement.
    # ClickHouse emits each projection as `PROJECTION <name> ( <query> )` inside the
    # column list. The body may itself contain parentheses (function calls,
    # nested expressions), so we balance parens rather than using a non-greedy regex.
    # Returns an array of [name, query] pairs with the body trimmed.
    def parse_projections(sql)
      results = []
      offset = 0
      while (match = sql.match(/PROJECTION (\S+) \(/, offset))
        name = match[1]
        body_start = match.end(0)
        depth = 1
        i = body_start
        while i < sql.length && depth.positive?
          case sql[i]
          when '(' then depth += 1
          when ')' then depth -= 1
          end
          i += 1
        end
        break if depth.positive?

        body = sql[body_start...(i - 1)].strip
        results << [name, body]
        offset = i
      end
      results
    end

    def index_parts(index)
      idx = index.match(/^INDEX (?<name>\S+) (?<expr>.*?) TYPE (?<type>.*?) GRANULARITY (?<granularity>\d+)$/)
      index_parts = [
        format_index_parts(idx['expr']),
        "name: #{format_index_parts(idx['name'])}",
        "type: #{format_index_parts(idx['type'])}"
      ]
      index_parts << "granularity: #{idx['granularity']}" if idx['granularity']
      index_parts
    end
  end
end
