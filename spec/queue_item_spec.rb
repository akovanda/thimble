# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::QueueItem, 'QueueItem' do
  context 'initialization' do
    it 'creates a queue item with an integer' do
      item = Thimble::QueueItem.new(42)
      expect(item.item).to eq(42)
      expect(item.id).not_to be_nil
    end

    it 'creates a queue item with a string' do
      item = Thimble::QueueItem.new('hello')
      expect(item.item).to eq('hello')
      expect(item.id).not_to be_nil
    end

    it 'creates a queue item with an array' do
      array = [1, 2, 3, 4, 5]
      item = Thimble::QueueItem.new(array)
      expect(item.item).to eq(array)
      expect(item.id).not_to be_nil
    end

    it 'creates a queue item with a custom name' do
      item = Thimble::QueueItem.new(42, 'CustomName')
      expect(item.item).to eq(42)
      expect(item.id).not_to be_nil
    end

    it 'creates a queue item with nil' do
      item = Thimble::QueueItem.new(nil)
      expect(item.item).to be_nil
      expect(item.id).not_to be_nil
    end
  end

  context 'uniqueness' do
    it 'creates unique IDs for different items' do
      item1 = Thimble::QueueItem.new(42)
      item2 = Thimble::QueueItem.new(42)
      expect(item1.id).not_to eq(item2.id)
    end

    it 'creates unique IDs for items created in sequence' do
      items = 10.times.map { |i| Thimble::QueueItem.new(i) }
      ids = items.map(&:id)
      expect(ids.uniq.size).to eq(10)
    end
  end

  context 'to_s method' do
    it 'returns a string representation with default name' do
      item = Thimble::QueueItem.new(42)
      str = item.to_s
      expect(str).to include('Item')
      expect(str).to include('42')
      expect(str).to include('ID:')
    end

    it 'returns a string representation with custom name' do
      item = Thimble::QueueItem.new(42, 'MyItem')
      str = item.to_s
      expect(str).to include('MyItem')
      expect(str).to include('42')
      expect(str).to include('ID:')
    end

    it 'handles complex objects in to_s' do
      item = Thimble::QueueItem.new([1, 2, 3])
      str = item.to_s
      expect(str).to include('Item')
      expect(str).to include('[1, 2, 3]')
    end
  end
end
