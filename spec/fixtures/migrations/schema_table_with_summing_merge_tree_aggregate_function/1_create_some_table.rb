# frozen_string_literal: true

class CreateSomeTable < ActiveRecord::Migration[7.1]
  def up
    create_table :some, id: false, options: 'AggregatingMergeTree() ORDER BY (date)' do |t|
      t.date :date, null: false
      t.column :col1, "AggregateFunction(sum, Float64)", null: false
      t.column :col2, "AggregateFunction(anyLast, Float64)", null: false
    end
  end
end
