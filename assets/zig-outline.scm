; Outline query: `@item` is the whole definition (its range), `@name` the node
; whose text is displayed. Zed's `outline.scm` shape; `@context` is tolerated
; and ignored. Overlapping patterns are fine — the first match for a given
; `@item` wins, so specific patterns come first.

(function_declaration name: (identifier) @name) @item

(test_declaration (string (string_content) @name)) @item

; Type declarations: `const Point = struct { … }` and friends. Matched at any
; depth, because a nested type is worth listing.
(variable_declaration
  (identifier) @name
  [
    (struct_declaration)
    (union_declaration)
    (enum_declaration)
    (error_set_declaration)
  ]) @item

; Every other binding only at file scope — a `const` inside a function body is
; a local, not an outline entry.
(source_file (variable_declaration (identifier) @name) @item)
