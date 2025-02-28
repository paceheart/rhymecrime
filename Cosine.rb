class Cosine
  def initialize vecA, vecB
    @vecA = vecA
    @vecB = vecB
  end

  def calculate_similarity
    return nil unless @vecA.is_a? Array
    return nil unless @vecB.is_a? Array
    return nil if @vecA.size != @vecB.size
    dot_product = 0
    @vecA.zip(@vecB).each do |v1i, v2i|
      dot_product += v1i * v2i
    end
    a = @vecA.map { |n| n ** 2 }.reduce(:+)
    b = @vecB.map { |n| n ** 2 }.reduce(:+)
    return dot_product / (Math.sqrt(a) * Math.sqrt(b))
  end
end
