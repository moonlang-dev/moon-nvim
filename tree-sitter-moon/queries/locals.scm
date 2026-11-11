; Local scopes, definitions, and references for moon.
; Monogram emits deliberately regular rule names, so these queries stay at
; the semantic wrappers instead of depending on target-specific field names.

; -- scopes -----------------------------------------------------------------
(function_definition) @local.scope
(extern_function) @local.scope
(interface_method) @local.scope
(impl_method) @local.scope
(block) @local.scope
(for_statement) @local.scope
(while_statement) @local.scope

; -- definitions ------------------------------------------------------------
(parameter
  (binding_name (identifier) @local.definition.parameter))
(closure_parameter
  (binding_name (identifier) @local.definition.parameter))

; Direct identifiers in patterns are bindings. Qualified names and enum
; variants are represented through `name` / `qualified_variant` instead.
(pattern (identifier) @local.definition.var)

(function_definition
  (function_name (name (identifier) @local.definition.function)))
(const_definition (identifier) @local.definition.constant)
(struct_definition (identifier) @local.definition.type)
(enum_definition (identifier) @local.definition.type)
(interface_definition (identifier) @local.definition.type)
(type_alias (identifier) @local.definition.type)
(loop_label (identifier) @local.definition.label)

; -- references -------------------------------------------------------------
(identifier) @local.reference
