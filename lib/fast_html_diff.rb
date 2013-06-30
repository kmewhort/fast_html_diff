require "fast_html_diff/version"
require 'nokogiri'

module FastHtmlDiff
  class DiffBuilder
    def initialize(html_str_a,html_str_b,config={})
      @a = html_str_a
      @b = html_str_b

      @config = default_config.merge(config)
      if config[:tokenizer_regexp].nil?
        if @config[:ignore_punctuation]
          @config[:tokenizer_regexp] = %r{([^A-Za-z0-9]+)}
        else
          @config[:tokenizer_regexp] = %r{(\s+)}
        end
      end

      @word_list = {}
      @insertions = []
      @deletions = []
      @split_nodes = Hash.new
      @insertion_nodes = Hash.new
    end

    def build
      # parse, tokenize and index
      @a = Nokogiri::HTML(@a)
      @b = Nokogiri::HTML(@b)
      if @config[:simplify_html]
        simplify_html(@a)
        simplify_html(@b)
      end
      index_document(@a, :a)
      index_document(@b, :b)

      # find the insertions and deletions
      diff_words

      # update doc a with tags for the insertions and deletions
      update_dom
      @a.to_html
    end

    private

    # index the words in the document
    def index_document(doc, doc_name)
      @word_list[doc_name] = Array.new

      # index each word of each text node
      preceding_chars = ""
      doc.xpath('//text()').each do |text_node|
        position = 0
        is_a_word = true
        text_node.content.split(@config[:tokenizer_regexp]).each_with_index do |word,i|
          # check whether we're starting with a word or a split itself
          if (i == 0) || (i == 1)
            is_a_word = !word.empty? && !word.match(@config[:tokenizer_regexp])
          else
            is_a_word = !is_a_word
          end

          if !is_a_word
            preceding_chars = word unless word.empty?
          else
            @word_list[doc_name] << {
              node: text_node,
              index_word: (@config[:case_insensitive] ? word.downcase : word),
              start_pos: position,
              end_pos: position + word.length,
              preceding_chars: preceding_chars
            }
            preceding_chars = ""
          end
          position += word.length
        end
      end
    end

    def diff_words
      # run diff on the word lists, using it as a quick, natively-run lcs algorithm
      diff_result = nil
      begin
        file_a = Tempfile.new('fast_html_diff_a')
        file_a.write  @word_list[:a].map{|w| w[:index_word]}.join("\n") + "\n"
        file_a.close

        file_b = Tempfile.new('fast_html_diff_b')
        file_b.write  @word_list[:b].map{|w| w[:index_word]}.join("\n") + "\n"
        file_b.close

        diff_args = "-U 100000" + (@config[:try_hard] ? ' -d' : '')
        diff_result = `#{@config[:diff_cmd]} #{diff_args} #{file_a.path} #{file_b.path}`
      ensure
        file_a.close
        file_a.unlink
        file_b.close
        file_b.unlink
      end

      # remap output back to the indexed word list
      doca_i = 0
      docb_i = 0
      prev_operation = :none
      diff_result.each_line do |word|
        next if word.match /^(---|\+\+\+|@@|\\\\)/ # skip info lines

        case word[0]
        when '+'
          if prev_operation == :insertion
            @insertions.last[:b_end] = docb_i
          else
            if prev_operation == :deletion
              @deletions.last[:next_operation] = :insertion
            end

            @insertions << {
                a_position: doca_i-1, #insert before the current word
                b_start: docb_i,
                b_end: docb_i,
                prev_operation: prev_operation
            }
            prev_operation = :insertion
          end
          docb_i += 1
        when '-'
          if prev_operation == :deletion
            @deletions.last[:a_end] = doca_i
          else
            if prev_operation == :insertion
              @insertions.last[:next_operation] = :insertion
            end

            @deletions << {
              a_start: doca_i,
              a_end: doca_i,
              prev_operation: prev_operation
            }
            prev_operation = :deletion
          end
          doca_i += 1
          else
            if prev_operation == :insertion
              @insertions.last[:next_operation] = :match
            elsif prev_operation == :deletion
              @deletions.last[:next_operation] = :match
            end

          prev_operation = :match
          doca_i += 1
          docb_i += 1
        end
        # if an additon is one past the end, keep the marker at the end
        doca_i = (@word_list[:a].length-1) if doca_i >= @word_list[:a].length
        docb_i = (@word_list[:b].length-1) if docb_i >= @word_list[:b].length
      end
    end

    # mark insertions and deletions in doc a
    def update_dom
      # prepare the nodes to insert before making any modifications
      @insertions.map! do |insertion|
        prepare_insertion(insertion)
      end

      # perform the insertions
      @insertions.each do |insertion|
        # if the insertion point's parent is the same type as the cca, merge the children
        # together; otherwise, insert the cca wholesale

        # TODO: handle case where a_position is -1 (insertion before start of document)

        # add whole nodes as-is and wrap partial nodes in a span
        additional_node = nil
        touches_node_start = @word_list[:b][insertion[:b_start]-1].nil? ||
            (@word_list[:b][insertion[:b_start]-1][:node] != @word_list[:b][insertion[:b_start]][:node])
        touches_node_end = @word_list[:b][insertion[:b_end]+1].nil? ||
            (@word_list[:b][insertion[:b_end]+1][:node] != @word_list[:b][insertion[:b_end]][:node])
        if touches_node_start && touches_node_end
          additional_node = insertion[:new_nodes]

          # bump the end char past whitespace/punctuation
          unless @word_list[:b][insertion[:b_end]+1].nil?
            insertion[:insertion_char_index] += @word_list[:b][insertion[:b_end]+1][:preceding_chars].length
          end
        else
          additional_node = Nokogiri::XML::Node.new('span', @a)
          if insertion[:new_nodes].children.length > 0
            insertion[:new_nodes].children.each {|c| additional_node.add_child(c) }
          else
            additional_node.add_child(insertion[:new_nodes])
          end
        end
        @insertion_nodes[additional_node] = true

        # insertions need to wrap around the text nodes
        additional_node.search('text()').each do |text_node|
          parent = text_node.parent
          wrapper = Nokogiri::XML::Node.new('ins', @a)
          wrapper.add_child(text_node)
          parent.add_child(wrapper)
        end

        # split the insertion point node (if necessary) and insert the new nodes
        modify_each_node_between(insertion[:insertion_point_node],
                                 insertion[:insertion_char_index], insertion[:insertion_char_index]) do |n|
          additional_node
        end
      end

      @deletions.each do |deletion|
        start_node = @word_list[:a][deletion[:a_start]][:node]
        start_char = @word_list[:a][deletion[:a_start]][:start_pos]
        end_node = @word_list[:a][deletion[:a_end]][:node]
        end_char = @word_list[:a][deletion[:a_end]][:end_pos]

        # wrap deletions in del tags just above each text node (so as to preserve
        # the original formatting)
        prev_node = cur_node = nil
        for word_i in deletion[:a_start]..deletion[:a_end]
          cur_node = @word_list[:a][word_i][:node]
          if cur_node != prev_node
            first = (cur_node == start_node) ? start_char : 0
            last = (cur_node == end_node) ? end_char : cur_node.content.length
            modify_each_node_between(cur_node, first, last) do |n|
              wrapper = Nokogiri::XML::Node.new('del', @a)
              wrapper.add_child(n)
              wrapper
            end
          end
          prev_node = cur_node
        end
      end
    end

    # build the exact DOM tree for an insertion
    def prepare_insertion(insertion)
      start_node = @word_list[:b][insertion[:b_start]][:node]
      start_char = @word_list[:b][insertion[:b_start]][:start_pos]
      end_node = @word_list[:b][insertion[:b_end]][:node]
      end_char = @word_list[:b][insertion[:b_end]][:end_pos]

      # find the closest common ancestor of the start and end, and clone this portion
      cca = (start_node.ancestors & end_node.ancestors).first
      cca_clone = cca.dup

      # find the start node in the clone by retracing the path
      path_to_cca = []
      target_node = start_node
      until target_node == cca
        path_to_cca.unshift target_node.parent.children.index(target_node)
        target_node = target_node.parent
      end
      start_node = cca_clone
      path_to_cca.each {|i| start_node = start_node.children[i]}

      # find the end node in the clone by retracing the path
      path_to_cca = []
      target_node = end_node
      until target_node == cca
        path_to_cca.unshift target_node.parent.children.index(target_node)
        target_node = target_node.parent
      end
      end_node = cca_clone
      path_to_cca.each {|i| end_node = end_node.children[i]}

      # trim away NODES up the tree that fall to the left of the start
      # or to the right of the end
      left_node = start_node
      while left_node != cca_clone
        siblings = left_node.parent.children
        self_index = siblings.index(left_node)
        unless self_index == 0
          left_of_self = siblings.slice(0..(self_index-1))
          left_of_self.each {|n| n.remove} unless left_of_self.nil?
        end
        left_node = left_node.parent
      end

      right_node = end_node
      while right_node != cca_clone
        siblings = right_node.parent.children
        self_index = siblings.index(right_node)
        right_of_self = siblings.slice((self_index+1)..-1)
        right_of_self.each {|n| n.remove} unless right_of_self.nil?
        right_node = right_node.parent
      end

      # trim away the TEXT that falls to the left of the start or to the right of
      # the end; also include the preceding characters to the insertion
      end_node.content = end_node.content[0..(end_char-1)]
      start_node.content = start_node.content[start_char..-1]

      # unless there's a deletion immediately before, include the preceding chars in the insertion
      unless (insertion[:prev_operation] == :deletion) || (insertion[:b_start] <= 0)
        start_node.content = @word_list[:b][insertion[:b_start]][:preceding_chars] + start_node.content
      end
      #unless (insertion[:next_operation] == :deletion) || (insertion[:b_end] >= @word_list[:b].length-1)
      #  end_node.content += @word_list[:b][insertion[:b_end]+1][:preceding_chars]
      #end

      insertion_data = {
        new_nodes: cca_clone,
        insertion_point_node: @word_list[:a][insertion[:a_position]][:node],
        insertion_char_index: @word_list[:a][insertion[:a_position]][:end_pos]
      }
      insertion.merge insertion_data
    end

    # splits nodes (if necessary) between the specified character positions
    # and runs the block for each node between the start and end
    def modify_each_node_between(node, start_char, end_char)
      prev_node_set = nil
      if @split_nodes[node].nil?
        prev_node_set = [node]
      else
        prev_node_set = @split_nodes[node]
      end

      # skip over inserted nodes, as they're not included in the character
      # counts (and there's no further operations on them)
      prev_node_set.delete_if {|n| @insertion_nodes[n] }

      new_node_set = []
      inside_nodes = []
      insertion_queue = Hash.new
      cur_char = 0
      start_trimmed = false
      end_trimmed = false
      prev_node_set.each do |n|
        cur_node = n
        new_node_set << cur_node
        node_end_char = cur_char + cur_node.content.length

        # split node at the start_char
        unless start_trimmed
          if start_char > node_end_char
            cur_char = node_end_char
            next
          else
            if start_char == cur_char
              start_trimmed = true
            else  # start_char beteen cur_char and node_end_char
              after_node = cur_node.dup
              cur_node.content = after_node.content[0..(start_char-cur_char-1)]
              after_node.content = after_node.content[(start_char-cur_char)..-1]
              insertion_queue[after_node] = cur_node # don't actually add_next_sibling yet, as Nokogiri will merge them
              start_trimmed = true

              cur_char += cur_node.content.length
              cur_node = after_node
              new_node_set << cur_node
            end
          end
        end

        # split node at the end_char
        unless end_trimmed || !start_trimmed
          inside_nodes << cur_node
          if end_char > node_end_char
            cur_char = node_end_char
            next
          elsif end_char == node_end_char
            end_trimmed = true
            cur_char = node_end_char
            next
          else # end_char < node_end_char
            after_node = cur_node.dup
            if (end_char-cur_char) > 0
              cur_node.content = after_node.content[0..(end_char-cur_char-1)]
              after_node.content = after_node.content[(end_char-cur_char)..-1]
            else
              cur_node.content = ""
            end
            insertion_queue[after_node] = cur_node
            end_trimmed = true

            new_node_set << after_node
          end
        end
        cur_char = node_end_char
      end
      new_node_set.map! do |node_in_set|
        insert_after = insertion_queue[node_in_set]
        if inside_nodes.include?(node_in_set) && block_given?
          modified_node = nil
          if !insert_after.nil?
            modified_node = yield node_in_set
            insert_after.add_next_sibling(modified_node)
          else
            node_parent = node_in_set.parent
            node_position = node_parent.children.index(node_in_set)
            modified_node = yield node_in_set

            # if the actual node has changed, need to rehook to parent (assume the origial has been removed)
            if modified_node != node_in_set
              if node_parent.children.length > node_position
                node_parent.children[node_position].add_previous_sibling(modified_node)
              else
                node_parent.add_child(modified_node)
              end
            end
          end

          # also need to update the insertion queue if a node referenced by
          # another has changed
          if modified_node != node_in_set
            insertion_queue.each do |floating_node, target_node|
              if target_node == node_in_set
                insertion_queue[floating_node] = modified_node
              end
            end
          end
          modified_node
        else
          insert_after.add_next_sibling(node_in_set) unless insert_after.nil?
          node_in_set
        end
      end

      @split_nodes[node] = new_node_set
    end

    def simplify_html(html)
      (html.css('*') - html.css(@config[:simplified_html_tags].join(','))).each do |node|
        node.replace(node.children)
      end
    end

    def default_config
      {
          ignore_punctuation: true,
          case_insensitive: true,
          tokenizer_regexp: %r{([^A-Za-z0-9]+)}, # overrides any ignore_punctuation setting
          diff_cmd: 'diff',
          try_hard: false,
          simplify_html: false,
          simplified_html_tags: ['html','body','p','strong','em','ul','ol','li']
      }
    end
  end
end
