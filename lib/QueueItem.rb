class QueueItem
  attr_reader :id, :item
  def initialize(item)
    @id = rand(10**100).to_s + Time.now.to_i.to_s
    @item = item
  end

end