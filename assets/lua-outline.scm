; Outline query — see assets/zig-outline.scm for the capture contract.

; `function M.g()` and `function M:h()` name the FIELD and the METHOD; a
; first-identifier heuristic reports the table ("M") for both, which is the
; concrete bug this query exists to fix.
(function_declaration
  name: [
    (identifier) @name
    (dot_index_expression field: (identifier) @name)
    (method_index_expression method: (identifier) @name)
  ]) @item

; `local f = function() … end` / `M.f = function() … end` — a binding whose
; value is a function, not every binding.
(assignment_statement
  (variable_list
    name: [
      (identifier) @name
      (dot_index_expression field: (identifier) @name)
    ])
  (expression_list value: (function_definition))) @item
