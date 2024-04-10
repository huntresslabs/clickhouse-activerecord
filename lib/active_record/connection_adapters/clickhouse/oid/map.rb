# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Clickhouse
      module OID # :nodoc:
        class Map < Type::Value # :nodoc:
          def initialize(sql_type)
            match_data = /map\(([^,]+),\s([^\)]+)\)/i.match(sql_type)
            @key_type = ClickhouseAdapter::TYPE_MAP.lookup(match_data[1])
            @value_type = ClickhouseAdapter::TYPE_MAP.lookup(match_data[2])
          end

          def type
            @value_type.type
          end

          def key_type
            @key_type.type
          end

          def serialize(value)
            if value.is_a?(Hash)
              value.each_with_object({}) { |(k, v), h| h[@key_type.serialize(k)] = @value_type.serialize(v) }
            else
              super
            end
          end
        end
      end
    end
  end
end