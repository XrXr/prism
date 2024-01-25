# frozen_string_literal: true

require "ruby_parser"

module Prism
  module Translation
    # This module is the entry-point for converting a prism syntax tree into the
    # seattlerb/ruby_parser gem's syntax tree.
    module RubyParser
      # A prism visitor that builds Sexp objects.
      class Compiler < ::Prism::Compiler
        # This is the name of the file that we are compiling. We set it on every
        # Sexp object that is generated, and also use it to compile __FILE__
        # nodes.
        attr_reader :file

        # Initialize a new compiler with the given file name.
        def initialize(file)
          @file = file
        end

        # alias foo bar
        # ^^^^^^^^^^^^^
        def visit_alias_method_node(node)
          s(node, :alias, visit(node.new_name), visit(node.old_name))
        end

        # alias $foo $bar
        # ^^^^^^^^^^^^^^^
        def visit_alias_global_variable_node(node)
          s(node, :valias, node.new_name.name, node.old_name.name)
        end

        # foo => bar | baz
        #        ^^^^^^^^^
        def visit_alternation_pattern_node(node)
          s(node, :or, visit(node.left), visit(node.right))
        end

        # a and b
        # ^^^^^^^
        def visit_and_node(node)
          s(node, :and, visit(node.left), visit(node.right))
        end

        # []
        # ^^
        def visit_array_node(node)
          s(node, :array).concat(visit_all(node.elements))
        end

        # foo => [bar]
        #        ^^^^^
        def visit_array_pattern_node(node)
          result = s(node, :array_pat, visit(node.constant)).concat(visit_all(node.requireds))
          result << :"*#{node.rest.expression&.name}" if node.rest.is_a?(SplatNode)
          result.concat(visit_all(node.posts))
        end

        # foo(bar)
        #     ^^^
        def visit_arguments_node(node)
          raise "Cannot visit arguments directly"
        end

        # { a: 1 }
        #   ^^^^
        def visit_assoc_node(node)
          [visit(node.key), visit(node.value)]
        end

        # def foo(**); bar(**); end
        #                  ^^
        #
        # { **foo }
        #   ^^^^^
        def visit_assoc_splat_node(node)
          if node.value.nil?
            [s(node, :kwsplat)]
          else
            [s(node, :kwsplat, visit(node.value))]
          end
        end

        # $+
        # ^^
        def visit_back_reference_read_node(node)
          s(node, :back_ref, node.name.name.delete_prefix("$").to_sym)
        end

        # begin end
        # ^^^^^^^^^
        def visit_begin_node(node)
          result = node.statements.nil? ? s(node, :nil) : visit(node.statements)

          if !node.rescue_clause.nil?
            if !node.statements.nil?
              result = s(node.statements, :rescue, result, visit(node.rescue_clause))
            else
              result = s(node.rescue_clause, :rescue, visit(node.rescue_clause))
            end

            current = node.rescue_clause
            until (current = current.consequent).nil?
              result << visit(current)
            end
          end

          if !node.else_clause&.statements.nil?
            result << visit(node.else_clause)
          end

          if !node.ensure_clause.nil?
            if !node.statements.nil? || !node.rescue_clause.nil? || !node.else_clause.nil?
              result = s(node.statements || node.rescue_clause || node.else_clause || node.ensure_clause, :ensure, result, visit(node.ensure_clause))
            else
              result = s(node.ensure_clause, :ensure, visit(node.ensure_clause))
            end
          end

          result
        end

        # foo(&bar)
        #     ^^^^
        def visit_block_argument_node(node)
          s(node, :block_pass, visit(node.expression))
        end

        # foo { |; bar| }
        #          ^^^
        def visit_block_local_variable_node(node)
          node.name
        end

        # A block on a keyword or method call.
        def visit_block_node(node)
          s(node, :block_pass, visit(node.expression))
        end

        # def foo(&bar); end
        #         ^^^^
        def visit_block_parameter_node(node)
          :"&#{node.name}"
        end

        # A block's parameters.
        def visit_block_parameters_node(node)
          result = node.parameters.nil? ? s(node, :args) : visit(node.parameters)

          if node.opening == "("
            result.line = node.opening_loc.start_line
            result.max_line = node.closing_loc.end_line
          end

          result << s(node, :shadow).concat(visit_all(node.locals)) if node.locals.any?
          result
        end

        # break
        # ^^^^^
        #
        # break foo
        # ^^^^^^^^^
        def visit_break_node(node)
          if node.arguments.nil?
            s(node, :break)
          elsif node.arguments.arguments.length == 1
            s(node, :break, visit(node.arguments.arguments.first))
          else
            s(node, :break, s(node.arguments, :array).concat(visit_all(node.arguments.arguments)))
          end
        end

        # foo
        # ^^^
        #
        # foo.bar
        # ^^^^^^^
        #
        # foo.bar() {}
        # ^^^^^^^^^^^^
        def visit_call_node(node)
          case node.name
          when :!~
            return s(node, :not, visit(node.copy(name: :"=~")))
          when :=~
            if node.arguments&.arguments&.length == 1 && node.block.nil?
              case node.receiver
              when StringNode
                return s(node, :match3, visit(node.arguments.arguments.first), visit(node.receiver))
              when RegularExpressionNode, InterpolatedRegularExpressionNode
                return s(node, :match2, visit(node.receiver), visit(node.arguments.arguments.first))
              end
            end
          end

          type = node.attribute_write? ? :attrasgn : :call
          type = :"safe_#{type}" if node.safe_navigation?

          arguments = node.arguments&.arguments || []
          block = node.block

          if block.is_a?(BlockArgumentNode)
            arguments << block
            block = nil
          end

          visit_block(node, s(node, type, visit(node.receiver), node.name).concat(visit_all(arguments)), block)
        end

        # foo.bar += baz
        # ^^^^^^^^^^^^^^^
        def visit_call_operator_write_node(node)
          if node.call_operator == "::"
            s(node, :op_asgn, visit(node.receiver), visit_write_value(node.value), node.read_name, node.operator)
          else
            s(node, :op_asgn2, visit(node.receiver), node.write_name, node.operator, visit_write_value(node.value))
          end
        end

        # foo.bar &&= baz
        # ^^^^^^^^^^^^^^^
        def visit_call_and_write_node(node)
          if node.call_operator == "::"
            s(node, :op_asgn, visit(node.receiver), visit_write_value(node.value), node.read_name, :"&&")
          else
            s(node, :op_asgn2, visit(node.receiver), node.write_name, :"&&", visit_write_value(node.value))
          end
        end

        # foo.bar ||= baz
        # ^^^^^^^^^^^^^^^
        def visit_call_or_write_node(node)
          if node.call_operator == "::"
            s(node, :op_asgn, visit(node.receiver), visit_write_value(node.value), node.read_name, :"||")
          else
            s(node, :op_asgn2, visit(node.receiver), node.write_name, :"||", visit_write_value(node.value))
          end
        end

        # foo.bar, = 1
        # ^^^^^^^
        def visit_call_target_node(node)
          s(node, :attrasgn, visit(node.receiver), node.name)
        end

        # foo => bar => baz
        #        ^^^^^^^^^^
        def visit_capture_pattern_node(node)
          visit(node.target) << visit(node.value)
        end

        # case foo; when bar; end
        # ^^^^^^^^^^^^^^^^^^^^^^^
        def visit_case_node(node)
          s(node, :case, visit(node.predicate)).concat(visit_all(node.conditions)) << visit(node.consequent)
        end

        # case foo; in bar; end
        # ^^^^^^^^^^^^^^^^^^^^^
        def visit_case_match_node(node)
          s(node, :case, visit(node.predicate)).concat(visit_all(node.conditions)) << visit(node.consequent)
        end

        # class Foo; end
        # ^^^^^^^^^^^^^^
        def visit_class_node(node)
          if node.body.nil?
            s(node, :class, node.name, visit(node.superclass))
          elsif node.body.is_a?(StatementsNode)
            s(node, :class, node.name, visit(node.superclass)).concat(visit_all(node.body.body))
          else
            s(node, :class, node.name, visit(node.superclass), visit(node.body))
          end
        end

        # @@foo
        # ^^^^^
        def visit_class_variable_read_node(node)
          s(node, :cvar, node.name)
        end

        # @@foo = 1
        # ^^^^^^^^^
        #
        # @@foo, @@bar = 1
        # ^^^^^  ^^^^^
        def visit_class_variable_write_node(node)
          s(node, :cvdecl, node.name, visit_write_value(node.value))
        end

        # @@foo += bar
        # ^^^^^^^^^^^^
        def visit_class_variable_operator_write_node(node)
          s(node, :cvdecl, node.name, s(node, :call, s(node, :cvar, node.name), node.operator, visit_write_value(node.value)))
        end

        # @@foo &&= bar
        # ^^^^^^^^^^^^^
        def visit_class_variable_and_write_node(node)
          s(node, :op_asgn_and, s(node, :cvar, node.name), s(node, :cvdecl, node.name, visit_write_value(node.value)))
        end

        # @@foo ||= bar
        # ^^^^^^^^^^^^^
        def visit_class_variable_or_write_node(node)
          s(node, :op_asgn_or, s(node, :cvar, node.name), s(node, :cvdecl, node.name, visit_write_value(node.value)))
        end

        # @@foo, = bar
        # ^^^^^
        def visit_class_variable_target_node(node)
          s(node, :cvdecl, node.name)
        end

        # Foo
        # ^^^
        def visit_constant_read_node(node)
          s(node, :const, node.name)
        end

        # Foo = 1
        # ^^^^^^^
        #
        # Foo, Bar = 1
        # ^^^  ^^^
        def visit_constant_write_node(node)
          s(node, :cdecl, node.name, visit(node.value))
        end

        # Foo += bar
        # ^^^^^^^^^^^
        def visit_constant_operator_write_node(node)
          s(node, :cdecl, node.name, s(node, :call, s(node, :const, node.name), node.operator, visit_write_value(node.value)))
        end

        # Foo &&= bar
        # ^^^^^^^^^^^^
        def visit_constant_and_write_node(node)
          s(node, :op_asgn_and, s(node, :const, node.name), s(node, :cdecl, node.name, visit(node.value)))
        end

        # Foo ||= bar
        # ^^^^^^^^^^^^
        def visit_constant_or_write_node(node)
          s(node, :op_asgn_or, s(node, :const, node.name), s(node, :cdecl, node.name, visit(node.value)))
        end

        # Foo, = bar
        # ^^^
        def visit_constant_target_node(node)
          s(node, :cdecl, node.name)
        end

        # Foo::Bar
        # ^^^^^^^^
        def visit_constant_path_node(node)
          if node.parent.nil?
            s(node, :colon3, node.child.name)
          else
            s(node, :colon2, visit(node.parent), node.child.name)
          end
        end

        # Foo::Bar = 1
        # ^^^^^^^^^^^^
        #
        # Foo::Foo, Bar::Bar = 1
        # ^^^^^^^^  ^^^^^^^^
        def visit_constant_path_write_node(node)
          s(node, :cdecl, visit(node.target), visit_write_value(node.value))
        end

        # Foo::Bar += baz
        # ^^^^^^^^^^^^^^^
        def visit_constant_path_operator_write_node(node)
          s(node, :op_asgn, visit(node.target), node.operator, visit_write_value(node.value))
        end

        # Foo::Bar &&= baz
        # ^^^^^^^^^^^^^^^^
        def visit_constant_path_and_write_node(node)
          s(node, :op_asgn_and, visit(node.target), visit_write_value(node.value))
        end

        # Foo::Bar ||= baz
        # ^^^^^^^^^^^^^^^^
        def visit_constant_path_or_write_node(node)
          s(node, :op_asgn_or, visit(node.target), visit_write_value(node.value))
        end

        # Foo::Bar, = baz
        # ^^^^^^^^
        def visit_constant_path_target_node(node)
          inner =
            if node.parent.nil?
              s(node, :colon3, node.child.name)
            else
              s(node, :colon2, visit(node.parent), node.child.name)
            end

          s(node, :const, inner)
        end

        # def foo; end
        # ^^^^^^^^^^^^
        #
        # def self.foo; end
        # ^^^^^^^^^^^^^^^^^
        def visit_def_node(node)
          parameters = node.parameters.nil? ? s(node, :args) : visit(node.parameters)
          body = node.body.nil? ? s(node, :nil) : visit(node.body)

          if node.receiver.nil?
            s(node, :defn, node.name, parameters, body)
          else
            s(node, :defs, visit(node.receiver), node.name, parameters, body)
          end
        end

        # defined? a
        # ^^^^^^^^^^
        #
        # defined?(a)
        # ^^^^^^^^^^^
        def visit_defined_node(node)
          s(node, :defined, visit(node.value))
        end

        # if foo then bar else baz end
        #                 ^^^^^^^^^^^^
        def visit_else_node(node)
          visit(node.statements)
        end

        # "foo #{bar}"
        #      ^^^^^^
        def visit_embedded_statements_node(node)
          result = s(node, :evstr)
          result << visit(node.statements) unless node.statements.nil?
          result
        end

        # "foo #@bar"
        #      ^^^^^
        def visit_embedded_variable_node(node)
          s(node, :evstr, visit(node.variable))
        end

        # begin; foo; ensure; bar; end
        #             ^^^^^^^^^^^^
        def visit_ensure_node(node)
          node.statements.nil? ? s(node, :nil) : visit(node.statements)
        end

        # false
        # ^^^^^
        def visit_false_node(node)
          s(node, :false)
        end

        # foo => [*, bar, *]
        #        ^^^^^^^^^^^
        def visit_find_pattern_node(node)
          s(node, :find_pat, visit(node.constant), :"*#{node.left.expression&.name}", *visit_all(node.requireds), :"*#{node.right.expression&.name}")
        end

        # if foo .. bar; end
        #    ^^^^^^^^^^
        def visit_flip_flop_node(node)
          if node.left.is_a?(IntegerNode) && node.right.is_a?(IntegerNode)
            s(node, :lit, Range.new(node.left.value, node.right.value, node.exclude_end?))
          else
            s(node, node.exclude_end? ? :flip3 : :flip2, visit(node.left), visit(node.right))
          end
        end

        # 1.0
        # ^^^
        def visit_float_node(node)
          s(node, :lit, node.value)
        end

        # for foo in bar do end
        # ^^^^^^^^^^^^^^^^^^^^^
        def visit_for_node(node)
          s(node, :for, visit(node.collection), visit(node.index), visit(node.statements))
        end

        # def foo(...); bar(...); end
        #                   ^^^
        def visit_forwarding_arguments_node(node)
          s(node, :forward_args)
        end

        # def foo(...); end
        #         ^^^
        def visit_forwarding_parameter_node(node)
          s(node, :forward_args)
        end

        # super
        # ^^^^^
        #
        # super {}
        # ^^^^^^^^
        def visit_forwarding_super_node(node)
          visit_block(node, s(node, :zsuper), node.block)
        end

        # $foo
        # ^^^^
        def visit_global_variable_read_node(node)
          s(node, :gvar, node.name)
        end

        # $foo = 1
        # ^^^^^^^^
        #
        # $foo, $bar = 1
        # ^^^^  ^^^^
        def visit_global_variable_write_node(node)
          s(node, :gasgn, node.name, visit_write_value(node.value))
        end

        # $foo += bar
        # ^^^^^^^^^^^
        def visit_global_variable_operator_write_node(node)
          s(node, :gasgn, node.name, s(node, :call, s(node, :gvar, node.name), node.operator, visit(node.value)))
        end

        # $foo &&= bar
        # ^^^^^^^^^^^^
        def visit_global_variable_and_write_node(node)
          s(node, :op_asgn_and, s(node, :gvar, node.name), s(node, :gasgn, node.name, visit_write_value(node.value)))
        end

        # $foo ||= bar
        # ^^^^^^^^^^^^
        def visit_global_variable_or_write_node(node)
          s(node, :op_asgn_or, s(node, :gvar, node.name), s(node, :gasgn, node.name, visit_write_value(node.value)))
        end

        # $foo, = bar
        # ^^^^
        def visit_global_variable_target_node(node)
          s(node, :gasgn, node.name)
        end

        # {}
        # ^^
        def visit_hash_node(node)
          s(node, :hash).concat(node.elements.flat_map { |element| visit(element) })
        end

        # foo => {}
        #        ^^
        def visit_hash_pattern_node(node)
          result = s(node, :hash_pat, visit(node.constant)).concat(node.elements.flat_map { |element| visit(element) })

          case node.rest
          when AssocSplatNode
            result << s(node.rest, :kwrest, :"**#{node.rest.value&.name}")
          when NoKeywordsParameterNode
            result << visit(node.rest)
          end

          result
        end

        # if foo then bar end
        # ^^^^^^^^^^^^^^^^^^^
        #
        # bar if foo
        # ^^^^^^^^^^
        #
        # foo ? bar : baz
        # ^^^^^^^^^^^^^^^
        def visit_if_node(node)
          s(node, :if, visit(node.predicate), visit(node.statements), visit(node.consequent))
        end

        # 1i
        def visit_imaginary_node(node)
          s(node, :lit, node.value)
        end

        # { foo: }
        #   ^^^^
        def visit_implicit_node(node)
        end

        # foo { |bar,| }
        #           ^
        def visit_implicit_rest_node(node)
        end

        # case foo; in bar; end
        # ^^^^^^^^^^^^^^^^^^^^^
        def visit_in_node(node)
          s(node, :in, visit(node.pattern)).concat(node.statements.nil? ? [nil] : visit_all(node.statements.body))
        end

        # foo[bar] += baz
        # ^^^^^^^^^^^^^^^
        def visit_index_operator_write_node(node)
          arglist = s(node, :arglist).concat(node.arguments&.arguments || [])
          s(node, :op_asgn1, visit(node.receiver), arglist, node.operator, visit_write_value(node.value))
        end

        # foo[bar] &&= baz
        # ^^^^^^^^^^^^^^^^
        def visit_index_and_write_node(node)
          arglist = s(node, :arglist).concat(visit_all(node.arguments&.arguments || []))
          s(node, :op_asgn1, visit(node.receiver), arglist, :"&&", visit_write_value(node.value))
        end

        # foo[bar] ||= baz
        # ^^^^^^^^^^^^^^^^
        def visit_index_or_write_node(node)
          arglist = s(node, :arglist).concat(visit_all(node.arguments&.arguments || []))
          s(node, :op_asgn1, visit(node.receiver), arglist, :"||", visit_write_value(node.value))
        end

        # foo[bar], = 1
        # ^^^^^^^^
        def visit_index_target_node(node)
          s(node, :attrasgn, visit(node.receiver), :[]=).concat(node.arguments&.arguments || [])
        end

        # @foo
        # ^^^^
        def visit_instance_variable_read_node(node)
          s(node, :ivar, node.name)
        end

        # @foo = 1
        # ^^^^^^^^
        #
        # @foo, @bar = 1
        # ^^^^  ^^^^
        def visit_instance_variable_write_node(node)
          s(node, :iasgn, node.name, visit_write_value(node.value))
        end

        # @foo += bar
        # ^^^^^^^^^^^
        def visit_instance_variable_operator_write_node(node)
          s(node, :iasgn, node.name, s(node, :call, s(node, :ivar, node.name), node.operator, visit_write_value(node.value)))
        end

        # @foo &&= bar
        # ^^^^^^^^^^^^
        def visit_instance_variable_and_write_node(node)
          s(node, :op_asgn_and, s(node, :ivar, node.name), s(node, :iasgn, node.name, visit(node.value)))
        end

        # @foo ||= bar
        # ^^^^^^^^^^^^
        def visit_instance_variable_or_write_node(node)
          s(node, :op_asgn_or, s(node, :ivar, node.name), s(node, :iasgn, node.name, visit(node.value)))
        end

        # @foo, = bar
        # ^^^^
        def visit_instance_variable_target_node(node)
          s(node, :iasgn, node.name)
        end

        # 1
        # ^
        def visit_integer_node(node)
          s(node, :lit, node.value)
        end

        # if /foo #{bar}/ then end
        #    ^^^^^^^^^^^^
        def visit_interpolated_match_last_line_node(node)
          s(node, :dregx).concat(visit_interpolated_parts(node.parts))
        end

        # /foo #{bar}/
        # ^^^^^^^^^^^^
        def visit_interpolated_regular_expression_node(node)
          s(node, :dregx).concat(visit_interpolated_parts(node.parts))
        end

        # "foo #{bar}"
        # ^^^^^^^^^^^^
        def visit_interpolated_string_node(node)
          s(node, :dstr).concat(visit_interpolated_parts(node.parts))
        end

        # :"foo #{bar}"
        # ^^^^^^^^^^^^^
        def visit_interpolated_symbol_node(node)
          s(node, :dsym).concat(visit_interpolated_parts(node.parts))
        end

        # `foo #{bar}`
        # ^^^^^^^^^^^^
        def visit_interpolated_x_string_node(node)
          children = visit_interpolated_parts(node.parts)
          s(node.heredoc? ? node.parts.first : node, :dxstr).concat(children)
        end

        # Visit the interpolated content of the string-like node.
        private def visit_interpolated_parts(parts)
          parts.each_with_object([]).with_index do |(part, results), index|
            if index == 0
              if part.is_a?(StringNode)
                results << part.unescaped
              else
                results << ""
                results << visit(part)
              end
            else
              results << visit(part)
            end
          end
        end

        # foo(bar: baz)
        #     ^^^^^^^^
        def visit_keyword_hash_node(node)
          s(node, :hash).concat(node.elements.flat_map { |element| visit(element) })
        end

        # def foo(**bar); end
        #         ^^^^^
        #
        # def foo(**); end
        #         ^^
        def visit_keyword_rest_parameter_node(node)
          :"**#{node.name}"
        end

        # -> {}
        def visit_lambda_node(node)
          parameters =
            case node.parameters
            when nil, NumberedParametersNode
              s(node, :args)
            else
              visit(node.parameters)
            end

          if node.body.nil?
            s(node, :iter, s(node, :lambda), parameters)
          else
            s(node, :iter, s(node, :lambda), parameters, visit(node.body))
          end
        end

        # foo
        # ^^^
        def visit_local_variable_read_node(node)
          if node.name.match?(/^_\d$/)
            s(node, :call, nil, node.name)
          else
            s(node, :lvar, node.name)
          end
        end

        # foo = 1
        # ^^^^^^^
        #
        # foo, bar = 1
        # ^^^  ^^^
        def visit_local_variable_write_node(node)
          s(node, :lasgn, node.name, visit_write_value(node.value))
        end

        # foo += bar
        # ^^^^^^^^^^
        def visit_local_variable_operator_write_node(node)
          s(node, :lasgn, node.name, s(node, :call, s(node, :lvar, node.name), node.operator, visit_write_value(node.value)))
        end

        # foo &&= bar
        # ^^^^^^^^^^^
        def visit_local_variable_and_write_node(node)
          s(node, :op_asgn_and, s(node, :lvar, node.name), s(node, :lasgn, node.name, visit_write_value(node.value)))
        end

        # foo ||= bar
        # ^^^^^^^^^^^
        def visit_local_variable_or_write_node(node)
          s(node, :op_asgn_or, s(node, :lvar, node.name), s(node, :lasgn, node.name, visit_write_value(node.value)))
        end

        # foo, = bar
        # ^^^
        def visit_local_variable_target_node(node)
          s(node, :lasgn, node.name)
        end

        # foo in bar
        # ^^^^^^^^^^
        def visit_match_predicate_node(node)
          s(node, :case, visit(node.value), s(node, :in, visit(node.pattern), nil), nil)
        end

        # foo => bar
        # ^^^^^^^^^^
        def visit_match_required_node(node)
          s(node, :case, visit(node.value), s(node, :in, visit(node.pattern), nil), nil)
        end

        # /(?<foo>foo)/ =~ bar
        # ^^^^^^^^^^^^^^^^^^^^
        def visit_match_write_node(node)
          s(node, :match2, visit(node.call.receiver), visit(node.call.arguments.arguments.first))
        end

        # A node that is missing from the syntax tree. This is only used in the
        # case of a syntax error. The parser gem doesn't have such a concept, so
        # we invent our own here.
        def visit_missing_node(node)
          raise "Cannot visit missing node directly"
        end

        # module Foo; end
        # ^^^^^^^^^^^^^^^
        def visit_module_node(node)
          constant_path = node.constant_path.is_a?(ConstantReadNode) ? node.constant_path.name : visit(node.constant_path)

          if node.body.nil?
            s(node, :module, constant_path)
          elsif node.body.is_a?(StatementsNode)
            s(node, :module, constant_path).concat(visit_all(node.body.body))
          else
            s(node, :module, constant_path, visit(node.body))
          end
        end

        # foo, bar = baz
        # ^^^^^^^^
        def visit_multi_target_node(node)
          targets = [*node.lefts]
          targets << node.rest if !node.rest.nil? && !node.rest.is_a?(ImplicitRestNode)
          targets.concat(node.rights)

          s(node, :masgn, s(node, :array).concat(visit_all(targets)))
        end

        # foo, bar = baz
        # ^^^^^^^^^^^^^^
        def visit_multi_write_node(node)
          targets = [*node.lefts]
          targets << node.rest if !node.rest.nil? && !node.rest.is_a?(ImplicitRestNode)
          targets.concat(node.rights)

          value = visit(node.value)
          if !node.value.is_a?(ArrayNode) || !node.value.opening_loc.nil?
            value = s(node, :to_ary, value)
          end

          s(node, :masgn, s(node, :array).concat(visit_all(targets)), value)
        end

        # next
        # ^^^^
        #
        # next foo
        # ^^^^^^^^
        def visit_next_node(node)
          if node.arguments.nil?
            s(node, :next)
          elsif node.arguments.arguments.length == 1
            argument = node.arguments.arguments.first
            s(node, :next, argument.is_a?(SplatNode) ? s(node, :svalue, visit(argument)) : visit(argument))
          else
            s(node, :next, s(node, :array).concat(visit_all(node.arguments.arguments)))
          end
        end

        # nil
        # ^^^
        def visit_nil_node(node)
          s(node, :nil)
        end

        # def foo(**nil); end
        #         ^^^^^
        def visit_no_keywords_parameter_node(node)
          :"**nil"
        end

        # -> { _1 + _2 }
        # ^^^^^^^^^^^^^^
        def visit_numbered_parameters_node(node)
          raise "Cannot visit numbered parameters directly"
        end

        # $1
        # ^^
        def visit_numbered_reference_read_node(node)
          s(node, :nth_ref, node.number)
        end

        # def foo(bar: baz); end
        #         ^^^^^^^^
        def visit_optional_keyword_parameter_node(node)
          s(node, :kwarg, node.name, visit(node.value))
        end

        # def foo(bar = 1); end
        #         ^^^^^^^
        def visit_optional_parameter_node(node)
          s(node, :lasgn, node.name, visit(node.value))
        end

        # a or b
        # ^^^^^^
        def visit_or_node(node)
          s(node, :or, visit(node.left), visit(node.right))
        end

        # def foo(bar, *baz); end
        #         ^^^^^^^^^
        def visit_parameters_node(node)
          children =
            node.compact_child_nodes.map do |element|
              if element.is_a?(MultiTargetNode)
                visit_destructured_parameter(element)
              else
                visit(element)
              end
            end

          s(node, :args).concat(children)
        end

        # def foo((bar, baz)); end
        #         ^^^^^^^^^^
        private def visit_destructured_parameter(node)
          children =
            [*node.lefts, *node.rest, *node.rights].map do |child|
              case child
              when RequiredParameterNode
                visit(child)
              when MultiTargetNode
                visit_destructured_parameter(child)
              when SplatNode
                :"*#{child.expression&.name}"
              else
                raise
              end
            end

          s(node, :masgn).concat(children)
        end

        # ()
        # ^^
        #
        # (1)
        # ^^^
        def visit_parentheses_node(node)
          if node.body.nil?
            s(node, :nil)
          else
            visit(node.body)
          end
        end

        # foo => ^(bar)
        #        ^^^^^^
        def visit_pinned_expression_node(node)
          visit(node.expression)
        end

        # foo = 1 and bar => ^foo
        #                    ^^^^
        def visit_pinned_variable_node(node)
          if node.variable.is_a?(LocalVariableReadNode) && node.variable.name.match?(/^_\d$/)
            s(node, :lvar, node.variable.name)
          else
            visit(node.variable)
          end
        end

        # END {}
        def visit_post_execution_node(node)
          s(node, :iter, s(node, :postexe), 0, visit(node.statements))
        end

        # BEGIN {}
        def visit_pre_execution_node(node)
          s(node, :iter, s(node, :preexe), 0, visit(node.statements))
        end

        # The top-level program node.
        def visit_program_node(node)
          visit(node.statements)
        end

        # 0..5
        # ^^^^
        def visit_range_node(node)
          if !node.left.nil? && !node.right.nil? && ([node.left.type, node.right.type] - %i[nil_node integer_node]).empty?
            left = node.left.value if node.left.is_a?(IntegerNode)
            right = node.right.value if node.right.is_a?(IntegerNode)
            s(node, :lit, Range.new(left, right, node.exclude_end?))
          else
            s(node, node.exclude_end? ? :dot3 : :dot2, visit(node.left), visit(node.right))
          end
        end

        # 1r
        # ^^
        def visit_rational_node(node)
          s(node, :lit, node.value)
        end

        # redo
        # ^^^^
        def visit_redo_node(node)
          s(node, :redo)
        end

        # /foo/
        # ^^^^^
        def visit_regular_expression_node(node)
          s(node, :lit, Regexp.new(node.unescaped, node.options))
        end

        # if /foo/ then end
        #    ^^^^^
        alias visit_match_last_line_node visit_regular_expression_node

        # def foo(bar:); end
        #         ^^^^
        def visit_required_keyword_parameter_node(node)
          s(node, :kwarg, node.name)
        end

        # def foo(bar); end
        #         ^^^
        def visit_required_parameter_node(node)
          node.name
        end

        # foo rescue bar
        # ^^^^^^^^^^^^^^
        def visit_rescue_modifier_node(node)
          s(node, :rescue, visit(node.expression), s(node, :resbody, s(node, :array), visit(node.rescue_expression)))
        end

        # begin; rescue; end
        #        ^^^^^^^
        def visit_rescue_node(node)
          exceptions = s(node, :array).concat(visit_all(node.exceptions))

          if !node.reference.nil?
            exceptions << (visit(node.reference) << s(node.reference, :gvar, :"$!"))
          end

          s(node, :resbody, exceptions).concat(node.statements.nil? ? [nil] : visit_all(node.statements.body))
        end

        # def foo(*bar); end
        #         ^^^^
        #
        # def foo(*); end
        #         ^
        def visit_rest_parameter_node(node)
          :"*#{node.name}"
        end

        # retry
        # ^^^^^
        def visit_retry_node(node)
          s(node, :retry)
        end

        # return
        # ^^^^^^
        #
        # return 1
        # ^^^^^^^^
        def visit_return_node(node)
          if node.arguments.nil?
            s(node, :return)
          elsif node.arguments.arguments.length == 1
            argument = node.arguments.arguments.first
            s(node, :return, argument.is_a?(SplatNode) ? s(node, :svalue, visit(argument)) : visit(argument))
          else
            s(node, :return, s(node, :array).concat(visit_all(node.arguments.arguments)))
          end
        end

        # self
        # ^^^^
        def visit_self_node(node)
          s(node, :self)
        end

        # class << self; end
        # ^^^^^^^^^^^^^^^^^^
        def visit_singleton_class_node(node)
          s(node, :sclass, visit(node.expression)).tap do |sexp|
            sexp << visit(node.body) unless node.body.nil?
          end
        end

        # __ENCODING__
        # ^^^^^^^^^^^^
        def visit_source_encoding_node(node)
          # TODO
          s(node, :colon2, s(node, :const, :Encoding), :UTF_8)
        end

        # __FILE__
        # ^^^^^^^^
        def visit_source_file_node(node)
          s(node, :str, file)
        end

        # __LINE__
        # ^^^^^^^^
        def visit_source_line_node(node)
          s(node, :lit, node.location.start_line)
        end

        # foo(*bar)
        #     ^^^^
        #
        # def foo((bar, *baz)); end
        #               ^^^^
        #
        # def foo(*); bar(*); end
        #                 ^
        def visit_splat_node(node)
          if node.expression.nil?
            s(node, :splat)
          else
            s(node, :splat, visit(node.expression))
          end
        end

        # A list of statements.
        def visit_statements_node(node)
          first, *rest = node.body

          if rest.empty?
            visit(first)
          else
            s(node, :block).concat(visit_all(node.body))
          end
        end

        # "foo"
        # ^^^^^
        def visit_string_node(node)
          s(node, :str, node.unescaped)
        end

        # super(foo)
        # ^^^^^^^^^^
        def visit_super_node(node)
          arguments = node.arguments&.arguments || []
          block = node.block

          if block.is_a?(BlockArgumentNode)
            arguments << block
            block = nil
          end

          visit_block(node, s(node, :super).concat(visit_all(arguments)), block)
        end

        # :foo
        # ^^^^
        def visit_symbol_node(node)
          node.value == "!@" ? s(node, :lit, :"!@") : s(node, :lit, node.unescaped.to_sym)
        end

        # true
        # ^^^^
        def visit_true_node(node)
          s(node, :true)
        end

        # undef foo
        # ^^^^^^^^^
        def visit_undef_node(node)
          names = node.names.map { |name| s(node, :undef, visit(name)) }
          names.length == 1 ? names.first : s(node, :block).concat(names)
        end

        # unless foo; bar end
        # ^^^^^^^^^^^^^^^^^^^
        #
        # bar unless foo
        # ^^^^^^^^^^^^^^
        def visit_unless_node(node)
          s(node, :if, visit(node.predicate), visit(node.consequent), visit(node.statements))
        end

        # until foo; bar end
        # ^^^^^^^^^^^^^^^^^
        #
        # bar until foo
        # ^^^^^^^^^^^^^
        def visit_until_node(node)
          s(node, :until, visit(node.predicate), visit(node.statements), !node.begin_modifier?)
        end

        # case foo; when bar; end
        #           ^^^^^^^^^^^^^
        def visit_when_node(node)
          s(node, :when, s(node, :array).concat(visit_all(node.conditions))).concat(node.statements.nil? ? [nil] : visit_all(node.statements.body))
        end

        # while foo; bar end
        # ^^^^^^^^^^^^^^^^^^
        #
        # bar while foo
        # ^^^^^^^^^^^^^
        def visit_while_node(node)
          s(node, :while, visit(node.predicate), visit(node.statements), !node.begin_modifier?)
        end

        # `foo`
        # ^^^^^
        def visit_x_string_node(node)
          result = s(node, :xstr, node.unescaped)

          if node.heredoc?
            result.line = node.content_loc.start_line
            result.max_line = node.content_loc.end_line
          end

          result
        end

        # yield
        # ^^^^^
        #
        # yield 1
        # ^^^^^^^
        def visit_yield_node(node)
          s(node, :yield).concat(visit_all(node.arguments&.arguments || []))
        end

        private

        # Create a new Sexp object from the given prism node and arguments.
        def s(node, *arguments)
          result = Sexp.new(*arguments)
          result.file = file
          result.line = node.location.start_line
          result.max_line = node.location.end_line
          result
        end

        # Visit a block node, which will modify the AST by wrapping the given
        # visited node in an iter node.
        def visit_block(node, sexp, block)
          if block.nil?
            sexp
          else
            parameters =
              case block.parameters
              when nil, NumberedParametersNode
                0
              else
                visit(block.parameters)
              end

            if block.body.nil?
              s(node, :iter, sexp, parameters)
            else
              s(node, :iter, sexp, parameters, visit(block.body))
            end
          end
        end

        # Visit the value of a write, which will be on the right-hand side of
        # a write operator. Because implicit arrays can have splats, those could
        # potentially be wrapped in an svalue node.
        def visit_write_value(node)
          if node.is_a?(ArrayNode) && node.opening_loc.nil? && node.elements.any? { |element| element.is_a?(SplatNode) }
            s(node, :svalue, visit(node))
          else
            visit(node)
          end
        end
      end

      private_constant :Compiler

      class << self
        # Parse the given source and translate it into the seattlerb/ruby_parser
        # gem's Sexp format.
        def parse(source)
          translate(Prism.parse(source), "(string)")
        end

        # Parse the given file and translate it into the seattlerb/ruby_parser
        # gem's Sexp format.
        def parse_file(filepath)
          translate(Prism.parse_file(filepath), filepath)
        end

        private

        # Translate the given parse result and filepath into the
        # seattlerb/ruby_parser gem's Sexp format.
        def translate(result, filepath)
          if result.failure?
            error = result.errors.first
            raise ::RubyParser::SyntaxError, "#{filepath}:#{error.location.start_line} :: #{error.message}"
          end

          result.value.accept(Compiler.new(filepath))
        end
      end
    end
  end
end
