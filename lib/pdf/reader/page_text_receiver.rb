# coding: utf-8

require 'forwardable'
require 'pdf/reader/page_layout'

module PDF
  class Reader

    # Builds a UTF-8 string of all the text on a single page by processing all
    # the operaters in a content stream.
    #
    # tdenovan 
    # => I have updated this class so that characters are first written to a buffer
    # => before being written to the @characters array. The buffer is written to
    # => the @characters array at the end of each text object. This allows text-object
    # => wide attributes to be set on each character within the text object (e.g. 
    # => whether estimated character spacing should be used because each text run
    # => contains a single character)
    class PageTextReceiver
      extend Forwardable

      SPACE = " "
      
      attr_reader :state, :content, :options, :characters, :mediabox

      ########## BEGIN FORWARDERS ##########
      # Graphics State Operators
      def_delegators :@state, :save_graphics_state, :restore_graphics_state

      # Matrix Operators
      def_delegators :@state, :concatenate_matrix

      # Text State Operators
      def_delegators :@state, :set_character_spacing, :set_horizontal_text_scaling
      def_delegators :@state, :set_text_font_and_size, :font_size
      def_delegators :@state, :set_text_leading, :set_text_rendering_mode
      def_delegators :@state, :set_text_rise, :set_word_spacing

      # Text Positioning Operators
      def_delegators :@state, :move_text_position, :move_text_position_and_set_leading
      def_delegators :@state, :set_text_matrix_and_text_line_matrix, :move_to_start_of_next_line
      ##########  END FORWARDERS  ##########

      # starting a new page
      def page=(page)
        @state = PageState.new(page)
        @content = []
        @characters = []
        @mediabox = page.objects.deref(page.attributes[:MediaBox])
      end

      def content
        PageLayout.new(@characters, @mediabox).to_s
      end

      #####################################################
      # Text Showing Operators
      #####################################################
      # record text that is drawn on the page
      def show_text(string) # Tj (AWAY)
        internal_show_text(string)
      end

      def show_text_with_positioning(params) # TJ [(A) 120 (WA) 20 (Y)]
        params.each do |arg|
          if arg.is_a?(String)
            internal_show_text(arg)
          else
            @state.process_glyph_displacement(0, arg, false)
          end
        end
      end

      def move_to_next_line_and_show_text(str) # '
        @state.move_to_start_of_next_line
        show_text(str)
      end

      def set_spacing_next_line_show_text(aw, ac, string) # "
        @state.set_word_spacing(aw)
        @state.set_character_spacing(ac)
        move_to_next_line_and_show_text(string)
      end
      
      # =========================
      # = Text object operators =
      # =========================
      
      def begin_text_object
        @characters_buffer = []
        @text_runs_buffer = [] # temporary record of text runs (not split into characters) per text object
        @state.begin_text_object
      end
      
      def end_text_object
        # write the buffered characters associated with the text object to the characters array
        estimate_character_spacing
        @characters.concat(@characters_buffer)
        @state.end_text_object
      end
      
      # ===================================
      # = Estimation of character spacing =
      # ===================================
      
      # This method estimates the character spacing of characters in a text object
      # It makes the estimate by using the most commonly occuring spacing within the text object
      # (i.e. the mode)
      # If less than 50% of the text runs in a text object contain single characters, then normal
      # character spacing is used (i.e. either the set characters spacing or character spacing implied
      # from the font size, rather than the text run positioning)
      def estimate_character_spacing
        # puts @text_runs_buffer.collect{|run| "'#{run.text}'"}
        return if @text_runs_buffer.count < 3
                
        # check if more than 50% of text runs contain only one character
        single_character_runs = @text_runs_buffer.reject{ |run| run.text.rstrip.length > 1}
        return if single_character_runs.count / @text_runs_buffer.count < 0.50
        
        # calculate the mode of character spacing (for adjacent text runs that contain only one character)
        character_spacings = []
        last_single_character_run = nil
        @text_runs_buffer.each do |run|
          last_single_character_run = nil if run.text.rstrip.length > 1
          character_spacings << run.x - last_single_character_run.x if last_single_character_run != nil
          last_single_character_run = run
        end
        mode_of_spacings = mode(character_spacings).first
        
        # update the characters buffer to flag that estimated character spacing should be used
        @characters_buffer.each{ |char| char.estimated_character_spacing = mode_of_spacings}
      end
      
      def mode(ary)
        seen = ::Hash.new(0)
        ary.each {|value| seen[value] += 1}
        max = seen.values.max
        seen.find_all {|key,value| value == max}.map {|key,value| key}
      end

      #####################################################
      # XObjects
      #####################################################
      def invoke_xobject(label)
        @state.invoke_xobject(label) do |xobj|
          case xobj
          when PDF::Reader::FormXObject then
            xobj.walk(self)
          end
        end
      end

      private

      def internal_show_text(string)
        if @state.current_font.nil?
          raise PDF::Reader::MalformedPDFError, "current font is invalid"
        end
                
        # save this text run to the buffer for the current text object
        newx, newy = @state.trm_transform(0,0)
        @text_runs_buffer << TextRun.new(newx, newy, nil, @state.font_size, string)
        
        # split the text run into individual characters
        glyphs = @state.current_font.unpack(string)
        glyphs.each_with_index do |glyph_code, index|
          # paint the current glyph
          newx, newy = @state.trm_transform(0,0)
          utf8_chars = @state.current_font.to_utf8(glyph_code)

          # apply to glyph displacment for the current glyph so the next
          # glyph will appear in the correct position
          glyph_width = @state.current_font.glyph_width(glyph_code) / 1000.0
          th = 1
          scaled_glyph_width = glyph_width * @state.font_size * th
          if utf8_chars != SPACE and utf8_chars.force_encoding("UTF-8").ascii_only?
            # Only save ascii chars
            @characters_buffer << TextRun.new(newx, newy, scaled_glyph_width, @state.font_size, utf8_chars) 
          end
          @state.process_glyph_displacement(glyph_width, 0, utf8_chars == SPACE)
        end
      end

    end
  end
end
