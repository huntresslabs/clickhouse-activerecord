# frozen_string_literal: true

class CreateSomeTable < ActiveRecord::Migration[7.1]
  def up
    create_table :some, id: false, force: true do |t|
      t.column :datetime64_tz, "DateTime64(3, 'UTC')", null: false
      t.column :datetime64_tz_nullable, "Nullable(DateTime64(3, 'UTC'))"
      t.datetime :datetime64, precision: 3, null: false
    end
  end
end
