# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::QueueItem do
  it 'preserves the wrapped value and provides a unique identifier' do
    first = described_class.new(42)
    second = described_class.new(42)

    expect(first.item).to eq(42)
    expect(first.id).to match(/\A[0-9a-f-]{36}\z/)
    expect(first.id).not_to eq(second.id)
  end

  it 'includes the name, value, and identifier in its string representation' do
    item = described_class.new([1, 2], 'Batch')

    expect(item.to_s).to include('Batch', '[1, 2]', item.id)
  end
end
