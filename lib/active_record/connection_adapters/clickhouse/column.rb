module ActiveRecord
  module ConnectionAdapters
    module Clickhouse
      class Column < ActiveRecord::ConnectionAdapters::Column
        attr_reader :codec

        def initialize(*, codec: nil, fixed_string: nil, **)
          super
          @codec = codec
          @fixed_string = fixed_string
        end

        def ==(other)
          other.is_a?(ActiveRecord::ConnectionAdapters::Clickhouse::Column) &&
            super &&
            codec == other.codec
        end
        alias eql? ==

        private

        def deduplicated
          self
        end
      end
    end
  end
end
