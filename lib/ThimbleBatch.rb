
class ThimbleBatch < QueueItem
  def to_s
    "batch: #{@item} \nID: #{@id}"
  end
end