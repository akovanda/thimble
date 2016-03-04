require "digest"
class QueueItem
  attr_reader :id, :item
  def initialize(item, name= "Item")
    @id = Digest::SHA256.digest(rand(10**100).to_s + Time.now.to_i.to_s)
    @item = item
    @name = name
  end

  def to_s
    "#{@name}: #{@item} \nID: #{@id}"
  end

end