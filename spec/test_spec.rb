require 'Thimble'

RSpec.describe Thimble, "Thimble" do 
  result = [1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000, 18000, 19000, 20000, 21000, 22000, 23000, 24000, 25000, 26000, 27000, 28000, 29000, 30000, 31000, 32000, 33000, 34000, 35000, 36000, 37000, 38000, 39000, 40000, 41000, 42000, 43000, 44000, 45000, 46000, 47000, 48000, 49000, 50000, 51000, 52000, 53000, 54000, 55000, 56000, 57000, 58000, 59000, 60000, 61000, 62000, 63000, 64000, 65000, 66000, 67000, 68000, 69000, 70000, 71000, 72000, 73000, 74000, 75000, 76000, 77000, 78000, 79000, 80000, 81000, 82000, 83000, 84000, 85000, 86000, 87000, 88000, 89000, 90000, 91000, 92000, 93000, 94000, 95000, 96000, 97000, 98000, 99000, 100000].sort
  context "map" do
    it "returns results correctly with fork" do
      c = Thimble::Manager.new(max_workers: 20, batch_size: 20, queue_size: 10)
      t = Thimble::Thimble.new((1..100).to_a, c)
      res = t.map do |i|
        i * 1000
      end
      expect(res.to_a.sort).to eq result

    end

    it "returns results correcly with thread" do 
      c = Thimble::Manager.new(max_workers: 20, batch_size: 20, queue_size: 10, worker_type: :thread)
      t = Thimble::Thimble.new((1..100).to_a, c)
      res = t.map do |i|
        i * 1000
      end
      expect(res.to_a.sort).to eq result
    end

    it "should get the proper results when two jobs happen at one time shaing a context" do
      c = Thimble::Manager.new(max_workers: 20, batch_size: 5, queue_size: 10, worker_type: :thread)
      t1 = Thimble::Thimble.new((1..100).to_a, c)
      t2 = Thimble::Thimble.new((1..100).to_a, c)
      res1 = nil
      thread1 = Thimble::Thimble.a_sync do 
        res1 = t1.map do |i|
          i * 1000
        end
      end
      res2 = nil
      thread2 = Thimble::Thimble.a_sync do
        res2 = t2.map do |i|
          i * 1000
        end
      end
      thread1.join
      thread2.join
      expect(res1.to_a.sort).to eq result
      expect(res2.to_a.sort).to eq result
    end

    it "should preserve arrays of arrays" do
      c = Thimble::Manager.new(max_workers: 5, batch_size: 1, queue_size: 10, worker_type: :fork)
      innerArray = [1,2,3,4,5]
      array = [innerArray.dup, innerArray.dup, innerArray.dup]
      t = Thimble::Thimble.new(array, c)
      res = t.map do |i|
        i.map {|e| e * 1000 }
      end
      resInner = innerArray.map { |e| e * 1000 }
      expect(res.to_a.sort).to eq [resInner, resInner, resInner]
    end

    it "handle the exception and raise it to the user" do
      c = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
      t1 = Thimble::Thimble.new((1..100).to_a, c)

      expect{t1.map {|r| r.count }.to_a.reduce(:+)}.to raise_exception(NoMethodError)
    end

    it "should convert to array properly" do
      c = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
      t1 = Thimble::Thimble.new((1..100).to_a, c)
      res = t1.map {|r| r }.reduce(:+)
      expect(res).to eq 5050
    end
  end
end
