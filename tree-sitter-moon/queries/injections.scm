; Language injections for moon.

; Re-parse each `${ ... }` payload as moon. Monogram names this wrapper after
; the template substitution it models; `$name` is a separate external token.
((string_literal_substitution (expr) @injection.content)
  (#set! injection.language "moon"))

; Let editor-side TODO/FIXME helpers treat line comments as comment text.
((line_comment) @injection.content
  (#set! injection.language "comment"))
