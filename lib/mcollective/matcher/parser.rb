# rubocop:disable Metrics/BlockNesting
module MCollective
  module Matcher
    class Parser
      attr_reader :scanner, :execution_stack

      def initialize(args)
        @scanner = Scanner.new(args)
        @execution_stack = []
        @parse_errors = []
        @token_errors = []
        @paren_errors = []
        parse
        exit_with_token_errors unless @token_errors.empty?
        exit_with_parse_errors unless @parse_errors.empty?
        exit_with_paren_errors unless @paren_errors.empty?
      end

      # Exit and highlight any malformed tokens
      def exit_with_token_errors
        @token_errors.each do |error_range|
          (error_range[0]..error_range[1]).each do |i|
            @scanner.arguments[i] = Util.colorize(:red, @scanner.arguments[i])
          end
        end
        raise "Malformed token(s) found while parsing -S input #{@scanner.arguments.join}"
      end

      def exit_with_parse_errors
        @parse_errors.each do |error_range|
          (error_range[0]..error_range[1]).each do |i|
            @scanner.arguments[i] = Util.colorize(:red, @scanner.arguments[i])
          end
        end
        raise "Parse errors found while parsing -S input #{@scanner.arguments.join}"
      end

      def exit_with_paren_errors
        @paren_errors.each do |i|
          @scanner.arguments[i] = Util.colorize(:red, @scanner.arguments[i])
        end
        raise "Missing parenthesis found while parsing -S input #{@scanner.arguments.join}"
      end

      # Parse the input string, one token at a time a contruct the call stack
      def parse # rubocop:disable Metrics/MethodLength
        pre_index = @scanner.token_index
        p_token = nil
        c_token, c_token_value = @scanner.get_token

        until c_token.nil?
          @scanner.token_index += 1
          n_token, n_token_value = @scanner.get_token

          unless n_token == " "
            case c_token
            when "bad_token"
              @token_errors << c_token_value

            when "and"
              unless (n_token =~ /not|fstatement|statement|\(/) || (scanner.token_index == scanner.arguments.size) && !n_token.nil?
                @parse_errors << [pre_index, scanner.token_index]
              end

              case p_token
              when nil
                @parse_errors << [pre_index - c_token.size, scanner.token_index]
              when "and", "or"
                @parse_errors << [pre_index - 1 - p_token.size, pre_index - 1]
              end

            when "or"
              unless (n_token =~ /not|fstatement|statement|\(/) || (scanner.token_index == scanner.arguments.size) && !n_token.nil?
                @parse_errors << [pre_index, scanner.token_index]
              end

              case p_token
              when nil
                @parse_errors << [pre_index - c_token.size, scanner.token_index]
              when "and", "or"
                @parse_errors << [pre_index - 1 - p_token.size, pre_index - 1]
              end

            when "not"
              @parse_errors << [pre_index, scanner.token_index] unless n_token =~ /fstatement|statement|\(|not/ && !n_token.nil?

            when "statement", "fstatement"
              @parse_errors << [pre_index, scanner.token_index] if n_token !~ /and|or|\)/ && scanner.token_index != scanner.arguments.size

            when ")"
              @parse_errors << [pre_index, scanner.token_index] if n_token !~ /|and|or|not|\(/ && scanner.token_index != scanner.arguments.size
              if @paren_errors.empty?
                @paren_errors.push(n_token.nil? ? scanner.token_index - 1 : scanner.token_index - n_token_value.size)
              else
                @paren_errors.pop
              end

            when "("
              @parse_errors << [pre_index, scanner.token_index] unless n_token =~ /fstatement|statement|not|\(/
              @paren_errors.push(n_token.nil? ? scanner.token_index - 1 : scanner.token_index - n_token_value.size)

            else
              @parse_errors << [pre_index, scanner.token_index]
            end

            @execution_stack << {c_token => c_token_value} unless n_token == " " || c_token == "bad_token"

            p_token = c_token
            c_token = n_token
            c_token_value = n_token_value
          end
          pre_index = @scanner.token_index
        end
      end
    end
  end
end
# rubocop:enable Metrics/BlockNesting
