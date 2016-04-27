require 'Thimble'

RSpec.describe Thimble::ThimbleQueue, "thimblequeue" do

  context "thimblequeue" do
    it "should not allow more data after being closed" do 
      q1 = Thimble::ThimbleQueue.new(10, "1")
      q1.close
      expect{q1.push(1)}.to raise_exception(RuntimeError)
    end

    it "should not accept more items than the given size" do
      ary = [1,2,3,4,5,6,7,8,9,10]
      q1 = Thimble::ThimbleQueue.new(5, "1")
      Thimble::Thimble.a_sync do 
        ary.each{ q1.push(ary.shift)}
      end
      sleep 1
      expect(ary.size).to eq (5)
    end

    it "should merge queues" do
      ary = [1,2,3,4,5,6,7,8,9,10]
      q1 = Thimble::ThimbleQueue.new(10, "1")
      q2 = Thimble::ThimbleQueue.new(10, "2")
      q1.push_flat(ary)
      q2.push_flat(ary)
      q1.close
      q2.close
      q3 = q1 +(q2)
      q3.close
      expect(q3.to_a.sort).to eq [1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10]
    end

    it "should merge an array and a queue" do
      ary = [1,2,3,4,5,6,7,8,9,10]
      q1 = Thimble::ThimbleQueue.new(10, "1")
      q1.push_flat(ary)
      q1.close
      q2 = q1 +(ary)
      q2.close
      expect(q2.to_a.sort).to eq [1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10]
    end

    it "should not close if now is not true or false" do
      q = Thimble::ThimbleQueue.new(10, "1")
      expect{q.close("stuff")}.to raise_exception(ArgumentError)
    end
  end
end
