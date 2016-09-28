def debug text
  puts text if $DEBUG
end

def debug(text, detail = 1)
  if $DEBUG_LEVEL >= detail
    puts "#{detail >= 3 ? '' : caller[0]} #{text}"
  end
end

class Array
  #array exists and has nth element (1=array start) not null
  def exists_and_has n
    size >= n && !at(n-1).nil?
  end

  def equal_partial? array
    each_with_index.all? { |a,i| :_ == a || :_ == array[i] || a == array[i] }
  end
end

class NilClass
  def exists_and_has n
    false
  end
end