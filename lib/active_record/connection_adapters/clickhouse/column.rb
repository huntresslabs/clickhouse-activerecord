module ActiveRecord
  module ConnectionAdapters
    module Clickhouse
      class Column < ActiveRecord::ConnectionAdapters::Column
        attr_reader :codec

        def initialize(*, codec: nil, **)
          super
          @codec = codec
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
