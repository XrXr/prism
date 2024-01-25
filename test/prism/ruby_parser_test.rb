# frozen_string_literal: true

return if RUBY_ENGINE == "jruby"

require_relative "test_helper"

begin
  require "ruby_parser"
rescue LoadError
  # In CRuby's CI, we're not going to test against the ruby_parser gem because
  # we don't want to have to install it. So in this case we'll just skip this
  # test.
  return
end

# We want to also compare lines and files to make sure we're setting them
# correctly.
Sexp.prepend(
  Module.new do
    def ==(other)
      super && line == other.line && max_line == other.max_line && file == other.file
    end
  end
)

module Prism
  class RubyParserTest < TestCase
    base = File.join(__dir__, "fixtures")

    todos = %w[
      arrays.txt
      dos_endings.txt
      heredoc_with_comment.txt
      heredocs_leading_whitespace.txt
      heredocs_nested.txt
      heredocs_with_ignored_newlines.txt
      newline_terminated.txt
      patterns.txt
      regex.txt
      rescue.txt
      seattlerb/bug169.txt
      seattlerb/bug179.txt
      seattlerb/case_in_array_pat_const2.txt
      seattlerb/case_in_multiple.txt
      seattlerb/case_in.txt
      seattlerb/defn_unary_not.txt
      seattlerb/difficult0_.txt
      seattlerb/dstr_evstr.txt
      seattlerb/dstr_str.txt
      seattlerb/heredoc__backslash_dos_format.txt
      seattlerb/heredoc_bad_hex_escape.txt
      seattlerb/heredoc_bad_oct_escape.txt
      seattlerb/heredoc_nested.txt
      seattlerb/heredoc_squiggly_blank_lines.txt
      seattlerb/heredoc_squiggly_interp.txt
      seattlerb/heredoc_squiggly_tabs_extra.txt
      seattlerb/heredoc_squiggly_tabs.txt
      seattlerb/heredoc_squiggly_visually_blank_lines.txt
      seattlerb/heredoc_squiggly.txt
      seattlerb/heredoc_with_carriage_return_escapes_windows.txt
      seattlerb/heredoc_with_extra_carriage_horrible_mix.txt
      seattlerb/heredoc_with_extra_carriage_returns_windows.txt
      seattlerb/heredoc_with_extra_carriage_returns.txt
      seattlerb/heredoc_with_interpolation_and_carriage_return_escapes_windows.txt
      seattlerb/heredoc_with_only_carriage_returns_windows.txt
      seattlerb/heredoc_with_only_carriage_returns.txt
      seattlerb/index_0_opasgn.txt
      seattlerb/masgn_colon3.txt
      seattlerb/messy_op_asgn_lineno.txt
      seattlerb/op_asgn_dot_ident_command_call.txt
      seattlerb/op_asgn_primary_colon_const_command_call.txt
      seattlerb/op_asgn_val_dot_ident_command_call.txt
      seattlerb/parse_line_defn_complex.txt
      seattlerb/parse_line_evstr_after_break.txt
      seattlerb/parse_line_to_ary.txt
      seattlerb/parse_pattern_019.txt
      seattlerb/parse_pattern_051.txt
      seattlerb/parse_pattern_076.txt
      seattlerb/pct_w_heredoc_interp_nested.txt
      seattlerb/regexp_esc_C_slash.txt
      seattlerb/safe_op_asgn.txt
      seattlerb/safe_op_asgn2.txt
      seattlerb/str_lit_concat_bad_encodings.txt
      seattlerb/str_pct_nested_nested.txt
      seattlerb/str_str_str.txt
      seattlerb/str_str.txt
      strings.txt
      tilde_heredocs.txt
      unescaping.txt
      unparser/corpus/literal/assignment.txt
      unparser/corpus/literal/block.txt
      unparser/corpus/literal/class.txt
      unparser/corpus/literal/def.txt
      unparser/corpus/literal/defs.txt
      unparser/corpus/literal/if.txt
      unparser/corpus/literal/kwbegin.txt
      unparser/corpus/literal/literal.txt
      unparser/corpus/literal/opasgn.txt
      unparser/corpus/literal/pattern.txt
      unparser/corpus/literal/send.txt
      unparser/corpus/literal/since/31.txt
      unparser/corpus/semantic/dstr.txt
      variables.txt
      whitequark/anonymous_blockarg.txt
      whitequark/asgn_mrhs.txt
      whitequark/blockargs.txt
      whitequark/cond_eflipflop.txt
      whitequark/cond_iflipflop.txt
      whitequark/cond_match_current_line.txt
      whitequark/dedenting_heredoc.txt
      whitequark/dedenting_interpolating_heredoc_fake_line_continuation.txt
      whitequark/dedenting_non_interpolating_heredoc_line_continuation.txt
      whitequark/lvar_injecting_match.txt
      whitequark/masgn_attr.txt
      whitequark/masgn_const.txt
      whitequark/masgn_splat.txt
      whitequark/op_asgn_cmd.txt
      whitequark/op_asgn_index_cmd.txt
      whitequark/op_asgn_index.txt
      whitequark/parser_slash_slash_n_escaping_in_literals.txt
      whitequark/ruby_bug_11990.txt
      whitequark/ruby_bug_12402.txt
      whitequark/ruby_bug_14690.txt
      whitequark/send_op_asgn_conditional.txt
      whitequark/slash_newline_in_heredocs.txt
      whitequark/space_args_block.txt
      whitequark/string_concat.txt
      whitequark/var_op_asgn.txt
    ]

    failures = %w[
      alias.txt
      method_calls.txt
      methods.txt
      not.txt
      seattlerb/and_multi.txt
      spanning_heredoc_newlines.txt
      spanning_heredoc.txt
      unparser/corpus/literal/since/27.txt
      while.txt
      whitequark/class_definition_in_while_cond.txt
      whitequark/if_while_after_class__since_32.txt
      whitequark/not.txt
      whitequark/pattern_matching_single_line_allowed_omission_of_parentheses.txt
      whitequark/pattern_matching_single_line.txt
      whitequark/ruby_bug_11989.txt
    ]

    Dir["**/*.txt", base: base].each do |name|
      next if failures.include?(name)

      define_method("test_#{name}") do
        begin
          # Parsing with ruby parser tends to be noisy with warnings, so we're
          # turning those off.
          previous_verbose, $VERBOSE = $VERBOSE, nil
          assert_parse_file(base, name, todos.include?(name))
        ensure
          $VERBOSE = previous_verbose
        end
      end
    end

    private

    def assert_parse_file(base, name, allowed_failure)
      filepath = File.join(base, name)
      expected = ::RubyParser.new.parse(File.read(filepath), filepath)
      actual = Prism::Translation::RubyParser.parse_file(filepath)

      if !allowed_failure
        assert_equal_nodes expected, actual
      elsif expected == actual
        puts "#{name} now passes"
      end
    end

    def assert_equal_nodes(left, right)
      return if left == right

      if left.is_a?(Sexp) && right.is_a?(Sexp)
        if left.line != right.line
          assert_equal "(#{left.inspect} line=#{left.line})", "(#{right.inspect} line=#{right.line})"
        elsif left.file != right.file
          assert_equal "(#{left.inspect} file=#{left.file})", "(#{right.inspect} file=#{right.file})"
        elsif left.length != right.length
          assert_equal "(#{left.inspect} length=#{left.length})", "(#{right.inspect} length=#{right.length})"
        else
          left.zip(right).each { |l, r| assert_equal_nodes(l, r) }
        end
      else
        assert_equal left, right
      end
    end
  end
end
