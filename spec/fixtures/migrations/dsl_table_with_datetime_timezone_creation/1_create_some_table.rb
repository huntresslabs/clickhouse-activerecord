# frozen_string_literal: true

class CreateSomeTable < ActiveRecord::Migration[7.1]
  def up
    # Timezone-qualified datetime types. The schema dumper must recover the
    # DateTime64 precision even though a timezone argument follows it; before the
    # extract_precision fix, `DateTime64(3, 'UTC')` dumped as a plain DateTime
    # (precision nil), silently dropping sub-second precision on schema load.
    create_table :some, id: false, force: true do |t|
      t.column :ts64_utc, "DateTime64(3, 'UTC')", null: false
      t.column :ts_utc, "DateTime('UTC')", null: false
    end
  end
end
