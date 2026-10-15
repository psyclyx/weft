; Outline query — see assets/zig-outline.scm for the capture contract.

(function_declaration name: (identifier) @name) @item
(method_declaration name: (field_identifier) @name) @item

; A type is its `type_spec`, not the `type` keyword's declaration, so each
; member of a grouped `type ( … )` gets its own entry. Only at file scope — a
; type declared inside a function body is a local.
(source_file (type_declaration (type_spec name: (type_identifier) @name) @item))
(source_file (type_declaration (type_alias name: (type_identifier) @name) @item))

; An interface's methods are its outline, the way a struct's are its methods.
(method_elem name: (field_identifier) @name) @item

; Package-level bindings, grouped or not; locals are not outline entries.
(source_file (const_declaration (const_spec name: (identifier) @name) @item))
(source_file (var_declaration (var_spec name: (identifier) @name) @item))
(source_file (var_declaration (var_spec_list (var_spec name: (identifier) @name) @item)))
