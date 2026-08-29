; Outline query — see assets/zig-outline.scm for the capture contract.

(function_declaration name: (identifier) @name) @item
(generator_function_declaration name: (identifier) @name) @item
(class_declaration name: (identifier) @name) @item
(method_definition name: (property_identifier) @name) @item

; `const g = () => {}` / `const h = function () {}`, but NOT `let j = 1`: a
; binding earns an outline entry by holding a function, not by existing.
(variable_declarator
  name: (identifier) @name
  value: [
    (arrow_function)
    (function_expression)
  ]) @item
