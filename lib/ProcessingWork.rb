class ProcessingWork
  def initialize(work, wr)
    @work = work
    @wr = wr
  end

  def start
    textArr = []
    textMap = {}
    (@work.stop - @work.start).times do |y|
      text = (0...50).map { ('a'..'z').to_a[rand(26)] }.join
      textArr << text
      textMap[text] = rand(100000)
    end
    @wr.write(Marshal.dump(WorkResult.new(textArr,textMap)))
    @wr.close
  end
end
