; This program and the accompanying materials are made available under the
; terms of the MIT license (X11 license) which accompanies this distribution.

; Author: C. Bürger

#!r6rs

(library
 (racr)
 (export
  ; Specification interface:
  (rename (make-racr-specification create-specification))
  with-specification
  (rename (specify-ast-rule ast-rule))
  (rename (specify-ag-rule ag-rule))
  specify-attribute
  compile-ast-specifications
  compile-ag-specifications
  ; Specification query interface:
  (rename
   (racr-specification-specification-phase specification->phase)
   (racr-specification-find-rule specification->find-ast-rule)
   (symbol-name symbol->name)
   (symbol-non-terminal? symbol->non-terminal?)
   (symbol-kleene? symbol->kleene?)
   (symbol-context-name symbol->context-name)
   (attribute-definition-name attribute->name)
   (attribute-definition-circular? attribute->circular?)
   (attribute-definition-synthesized? attribute->synthesized?)
   (attribute-definition-inherited? attribute->inherited?)
   (attribute-definition-cached? attribute->cached?))
  specification->ast-rules
  ast-rule->production
  symbol->attributes
  ; AST construction interface:
  create-ast
  create-ast-list
  create-ast-bud
  create-ast-mockup
  ; AST & attribute query interface:
  (rename (node? ast-node?))
  ast-node-type
  ast-list-node?
  (rename (node-bud-node? ast-bud-node?))
  ast-subtype?
  ast-parent
  ast-child
  ast-sibling
  ast-child-index
  ast-num-children
  ast-children
  ast-for-each-child
  ast-find-child
  att-value
  ; Rewrite interface:
  perform-rewrites
  rewrite-terminal
  rewrite-refine
  rewrite-abstract
  rewrite-subtree
  rewrite-add
  rewrite-insert
  rewrite-delete
  ; AST annotation interface:
  ast-weave-annotations
  ast-annotation?
  ast-annotation
  ast-annotation-set!
  ast-annotation-remove!
  ; Utility interface:
  print-ast
  racr-exception?)
 (import (rnrs) (rnrs mutable-pairs))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Internal Data Structures ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 ; Constructor for unique entities internally used by the RACR system
 (define-record-type racr-nil-record (sealed #t) (opaque #t))
 (define racr-nil (make-racr-nil-record)) ; Unique value indicating undefined RACR entities
 
 ; Record type representing RACR compiler specifications. A compiler specification consists of arbitrary
 ; many AST rule, attribute and rewrite specifications, all aggregated into a set of rules stored in a
 ; non-terminal-symbol -> ast-rule hashtable, an actual compiler specification phase and a distinguished
 ; start symbol. The specification phase is an internal flag indicating the RACR system the compiler's
 ; specification progress. Possible phases are:
 ; 1 : AST specification
 ; 2 : AG specification
 ; 3 : Rewrite specification
 ; 4 : Specification finished
 (define-record-type racr-specification
   (fields (mutable specification-phase) rules-table (mutable start-symbol))
   (protocol
    (lambda (new)
      (lambda ()
        (new 1 (make-eq-hashtable 50) racr-nil)))))
 
 ; INTERNAL FUNCTION: Given a RACR specification and a non-terminal, return the
 ; non-terminal's AST rule or #f if it is undefined.
 (define racr-specification-find-rule
   (lambda (spec non-terminal)
     (hashtable-ref (racr-specification-rules-table spec) non-terminal #f)))
 
 ; INTERNAL FUNCTION: Given a RACR specification return a list of its AST rules.
 (define racr-specification-rules-list
   (lambda (spec)
     (call-with-values
      (lambda ()
        (hashtable-entries (racr-specification-rules-table spec)))
      (lambda (key-vector value-vector)
        (vector->list value-vector)))))
 
 ; Record type for AST rules; An AST rule has a reference to the RACR specification it belongs to and consist
 ; of its symbolic encoding, a production (i.e., a list of production-symbols) and an optional supertype.
 (define-record-type ast-rule
   (fields specification as-symbol (mutable production) (mutable supertype?)))
 
 ; INTERNAL FUNCTION: Given two rules r1 and r2, return whether r1 is a subtype of r2 or not. The subtype
 ; relationship is reflexive, i.e., every type is a subtype of itself.
 ; BEWARE: Only works correct if supertypes are resolved, otherwise an exception can be thrown!
 (define ast-rule-subtype?
   (lambda (r1 r2)
     (and
      (eq? (ast-rule-specification r1) (ast-rule-specification r2))
      (let loop ((r1 r1))
        (cond
          ((eq? r1 r2) #t)
          ((ast-rule-supertype? r1) (loop (ast-rule-supertype? r1)))
          (else #f))))))
 
 ; INTERNAL FUNCTION: Given a rule, return a list containing all its subtypes except the rule itself.
 ; BEWARE: Only works correct if supertypes are resolved, otherwise an exception can be thrown!
 (define ast-rule-subtypes
   (lambda (rule1)
     (filter
      (lambda (rule2)
        (and (not (eq? rule2 rule1)) (ast-rule-subtype? rule2 rule1)))
      (racr-specification-rules-list (ast-rule-specification rule1)))))
 
 ; Record type for production symbols; A production symbol has a name, a flag indicating whether it is a
 ; non-terminal or not (later resolved to the actual AST rule representing the respective non-terminal), a
 ; flag indicating whether it represents a Kleene closure (i.e., is a list of certain type) or not, a
 ; context-name unambiguously referencing it within the production it is part of and a list of attributes
 ; defined for it.
 (define-record-type (symbol make-production-symbol production-symbol?)
   (fields name (mutable non-terminal?) kleene? context-name (mutable attributes)))
 
 ; Record type for attribute definitions. An attribute definition has a certain name, a definition context
 ; consisting of an AST rule and an attribute position (i.e., a (ast-rule position) pair), an equation, and
 ; an optional circularity-definition needed for circular attributes' fix-point computations. Further,
 ; attribute definitions specify whether the value of instances of the defined attribute are cached.
 ; Circularity-definitions are (bottom-value equivalence-function) pairs, whereby bottom-value is the value
 ; fix-point computations start with and equivalence-functions are used to decide whether a fix-point is
 ; reached or not (i.e., equivalence-functions are arbitrary functions of arity two computing whether two
 ; given arguments are equal or not).
 (define-record-type attribute-definition
   (fields name context equation circularity-definition cached?))
 
 ; INTERNAL FUNCTION: Given an attribute definition, check if instances can depend on
 ; themself (i.e., be circular) or not.
 (define attribute-definition-circular?
   (lambda (att)
     (if (attribute-definition-circularity-definition att) #t #f)))
 
 ; INTERNAL FUNCTION: Given an attribute definition, return whether it specifies
 ; a synthesized attribute or not.
 (define attribute-definition-synthesized?
   (lambda (att-def)
     (= (cdr (attribute-definition-context att-def)) 0)))
 
 ; INTERNAL FUNCTION: Given an attribute definition, return whether it specifies
 ; an inherited attribute or not.
 (define attribute-definition-inherited?
   (lambda (att-def)
     (not (attribute-definition-synthesized? att-def))))
 
 ; Record type for AST nodes. AST nodes have a reference to the evaluator state used for evaluating their
 ; attributes and rewrites, the AST rule they represent a context of, their parent, children, attribute
 ; instances, attribute cache entries they influence and annotations.
 (define-record-type node
   (fields
    (mutable evaluator-state)
    (mutable ast-rule)
    (mutable parent)
    (mutable children)
    (mutable attributes)
    (mutable cache-influences)
    (mutable annotations))
   (protocol
    (lambda (new)
      (lambda (ast-rule parent children)
        (new
         #f
         ast-rule
         parent
         children
         (list)
         (list)
         (list))))))
 
 ; INTERNAL FUNCTION: Given a node, return whether it is a terminal or not.
 (define node-terminal?
   (lambda (n)
     (eq? (node-ast-rule n) 'terminal)))
 
 ; INTERNAL FUNCTION: Given a node, return whether it is a non-terminal or not.
 (define node-non-terminal?
   (lambda (n)
     (not (node-terminal? n))))
 
 ; INTERNAL FUNCTION: Given a node, return whether it represents a list of
 ; children, i.e., is a list-node, or not.
 (define node-list-node?
   (lambda (n)
     (eq? (node-ast-rule n) 'list-node)))
 
 ; INTERNAL FUNCTION: Given a node, return whether is is a bud-node or not.
 (define node-bud-node?
   (lambda (n)
     (eq? (node-ast-rule n) 'bud-node)))
 
 ; INTERNAL FUNCTION: Given a node, return its child-index. An exception is thrown,
 ; if the node has no parent (i.e., is a root).
 (define node-child-index
   (lambda (n)
     (if (node-parent n)
         (let loop ((children (node-children (node-parent n)))
                    (pos 1))
           (if (eq? (car children) n)
               pos
               (loop (cdr children) (+ pos 1))))
         (throw-exception
          "Cannot access child-index; "
          "The node has no parent!"))))
 
 ; INTERNAL FUNCTION: Given a node find a certain child by name. If the node has
 ; no such child, return #f, otherwise the child.
 (define node-find-child
   (lambda (n context-name)
     (and (not (node-list-node? n))
          (not (node-bud-node? n))
          (not (node-terminal? n))
          (let loop ((contexts (cdr (ast-rule-production (node-ast-rule n))))
                     (children (node-children n)))
            (if (null? contexts)
                #f
                (if (eq? (symbol-context-name (car contexts)) context-name)
                    (car children)
                    (loop (cdr contexts) (cdr children))))))))
 
 ; INTERNAL FUNCTION: Given a node find a certain attribute associated with it. If the node
 ; has no such attribute, return #f, otherwise the attribute.
 (define node-find-attribute
   (lambda (n name)
     (find
      (lambda (att)
        (eq? (attribute-definition-name (attribute-instance-definition att)) name))
      (node-attributes n))))
 
 ; INTERNAL FUNCTION: Given two nodes n1 and n2, return whether n1 is within the subtree spaned by n2 or not.
 (define node-inside-of?
   (lambda (n1 n2)
     (cond
       ((eq? n1 n2) #t)
       ((node-parent n1) (node-inside-of? (node-parent n1) n2))
       (else #f))))
 
 ; Record type for attribute instances of a certain attribute definition, associated with
 ; a certain node (context) and a cache.
 (define-record-type attribute-instance
   (fields (mutable definition) (mutable context) cache)
   (protocol
    (lambda (new)
      (lambda (definition context)
        (new definition context (make-hashtable equal-hash equal? 1))))))
 
 ; Record type for attribute cache entries. Attribute cache entries represent the values of
 ; and dependencies between attribute instances evaluated for certain arguments. The attribute
 ; instance of which an entry represents a value is called its context. If an entry already
 ; is evaluated, it caches the result of its context evaluated for its arguments. If an entry is
 ; not evaluated but its context is circular it stores an intermediate result of its fixpoint
 ; computation, called cycle value. Entries also track whether they are already in evaluation or
 ; not, such that the attribute evaluator can detect unexpected cycles.
 (define-record-type attribute-cache-entry
   (fields
    (mutable context)
    (mutable arguments)
    (mutable value)
    (mutable cycle-value)
    (mutable entered?)
    (mutable node-dependencies)
    (mutable cache-dependencies)
    (mutable cache-influences))
   (protocol
    (lambda (new)
      (lambda (att arguments) ; att: The attribute instance for which to construct a cache entry
        (new
         att
         arguments
         racr-nil
         (let ((circular? (attribute-definition-circularity-definition (attribute-instance-definition att))))
           (if circular?
               (car circular?)
               racr-nil))
         #f
         (list)
         (list)
         (list))))))
 
 ; Record type representing the internal state of RACR systems throughout their execution, i.e., while
 ; evaluating attributes and rewriting ASTs. An evaluator state consists of a flag indicating if the AG
 ; currently performs a fix-point evaluation, a flag indicating if throughout a fix-point iteration the
 ; value of an attribute changed and an attribute evaluation stack used for dependency tracking.
 (define-record-type evaluator-state
   (fields (mutable ag-in-cycle?) (mutable ag-cycle-change?) (mutable evaluation-stack))
   (protocol
    (lambda (new)
      (lambda ()
        (new #f #f (list))))))
 
 ; INTERNAL FUNCTION: Given an evaluator state, return whether it represents an evaluation in progress or
 ; not; If it represents an evaluation in progress return the current attribute in evaluation, otherwise #f.
 (define evaluator-state-in-evaluation?
   (lambda (state)
     (and (not (null? (evaluator-state-evaluation-stack state))) (car (evaluator-state-evaluation-stack state)))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Specification Query Interface ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 (define specification->ast-rules
   (lambda (spec)
     (append (racr-specification-rules-list spec) (list)))) ; Create copy!
 
 (define ast-rule->production
   (lambda (rule)
     (append (ast-rule-production rule) (list)))) ; Create copy!
 
 (define symbol->attributes
   (lambda (symbol)
     (append (symbol-attributes symbol) (list)))) ; Create copy!
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Utility ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 ; INTERNAL FUNCTION: Given an arbitrary Scheme entity, construct a string
 ; representation of it using display.
 (define object->string
   (lambda (x)
     (call-with-string-output-port
      (lambda (port)
        (display x port)))))
 
 (define-condition-type racr-exception &violation make-racr-exception racr-exception?)
 
 ; INTERNAL FUNCTION: Given an arbitrary sequence of strings and other Scheme entities, concatenate them to
 ; form an error message and throw a special RACR exception with the constructed message. Any entity that is
 ; not a string is treated as error information embedded in the error message between [ and ] characters,
 ; whereby the actual string representation of the entity is obtained using object->string.
 (define-syntax throw-exception
   (syntax-rules ()
     ((_ m-part ...)
      (raise-continuable
       (condition
        (make-racr-exception)
        (make-message-condition
         (string-append
          "RACR exception: "
          (let ((m-part* m-part))
            (if (string? m-part*)
                m-part*
                (string-append "[" (object->string m-part*) "]"))) ...)))))))
 
 ; INTERNAL FUNCTION: Procedure sequentially applying a function on all the AST rules of a set of rules which
 ; inherit, whereby supertypes are processed before their subtypes.
 (define apply-wrt-ast-inheritance
   (lambda (func rules)
     (let loop ((resolved ; The set of all AST rules that are already processed....
                 (filter ; ...Initially it consists of all the rules that have no supertypes.
                  (lambda (rule)
                    (not (ast-rule-supertype? rule)))
                  rules))
                (to-check ; The set of all AST rules that still must be processed....
                 (filter ; ...Initially it consists of all the rules that have supertypes.
                  (lambda (rule)
                    (ast-rule-supertype? rule))
                  rules)))
       (let ((to-resolve ; ...Find a rule that still must be processed and...
              (find
               (lambda (rule)
                 (memq (ast-rule-supertype? rule) resolved)) ; ...whose supertype already has been processed....
               to-check)))
         (when to-resolve ; ...If such a rule exists,...
           (func to-resolve) ; ...process it and...
           (loop (cons to-resolve resolved) (remq to-resolve to-check))))))) ; ...recur.
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Support API ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 ; Given an AST, an association list L of attribute pretty-printers and an output port, print a
 ; human-readable ASCII representation of the AST on the output port. The elements of the association list
 ; L are (attribute-name pretty-printing-function) pairs. Every attribute for which L contains an entry is
 ; printed when the AST node it is associated with is printed. Thereby, the given pretty printing function
 ; is applied to the attribute's value before printing it. Beware: The output port is never closed by this
 ; function - neither in case of an io-exception nor after finishing printing the AST.
 (define print-ast
   (lambda (ast attribute-pretty-printer-list output-port)
     (letrec ((print-indentation
               (lambda (n)
                 (if (> n 0)
                     (begin
                       (print-indentation (- n 1))
                       (my-display " |"))
                     (my-display #\newline))))
              (my-display
               (lambda (to-display)
                 (display to-display output-port))))
       (let loop ((ast-depth 0)
                  (ast ast))
         (cond
           ((node-list-node? ast) ; Print list nodes
            (print-indentation ast-depth)
            (print-indentation ast-depth)
            (my-display "-* ")
            (my-display
             (symbol->string
              (symbol-name
               (list-ref
                (ast-rule-production (node-ast-rule (node-parent ast)))
                (ast-child-index ast)))))
            (for-each
             (lambda (element)
               (loop (+ ast-depth 1) element))
             (node-children ast)))
           ((node-bud-node? ast) ; Print bud nodes
            (print-indentation ast-depth)
            (print-indentation ast-depth)
            (my-display "-@ bud-node"))
           ((node-non-terminal? ast) ; Print non-terminal
            (print-indentation ast-depth)
            (print-indentation ast-depth)
            (my-display "-\\ ")
            (my-display (symbol->string (ast-node-type ast)))
            (for-each
             (lambda (att)
               (let* ((name (attribute-definition-name (attribute-instance-definition att)))
                      (pretty-printer-entry (assq name attribute-pretty-printer-list)))
                 (when pretty-printer-entry
                   (print-indentation (+ ast-depth 1))
                   (my-display " <")
                   (my-display (symbol->string name))
                   (my-display "> ")
                   (my-display ((cdr pretty-printer-entry) (att-value name ast))))))
             (node-attributes ast))
            (for-each
             (lambda (child)
               (loop (+ ast-depth 1) child))
             (node-children ast)))
           (else ; Print terminal
            (print-indentation ast-depth)
            (my-display "- ")
            (my-display (node-children ast)))))
       (my-display #\newline))))
 
 (define-syntax with-specification
   (lambda (x)
     (syntax-case x ()
       ((k spec body ...)
        #`(let* ((spec* spec)
                 (#,(datum->syntax #'k 'ast-rule)
                  (lambda (rule)
                    (specify-ast-rule spec* rule)))
                 (#,(datum->syntax #'k 'compile-ast-specifications)
                  (lambda (start-symbol)
                    (compile-ast-specifications spec* start-symbol)))
                 (#,(datum->syntax #'k 'compile-ag-specifications)
                  (lambda ()
                    (compile-ag-specifications spec*)))
                 (#,(datum->syntax #'k 'create-ast)
                  (lambda (rule children)
                    (create-ast spec* rule children)))
                 (#,(datum->syntax #'k 'specification-phase)
                  (lambda ()
                    (racr-specification-specification-phase spec*)))
                 (#,(datum->syntax #'k 'specify-attribute)
                  (lambda (att-name non-terminal index cached? equation circ-def)
                    (specify-attribute spec* att-name non-terminal index cached? equation circ-def))))
            (let-syntax ((#,(datum->syntax #'k 'ag-rule)
                          (syntax-rules ()
                            ((_ attribute-name definition (... ...))
                             (specify-ag-rule spec* attribute-name definition (... ...))))))
              body ...))))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Abstract Syntax Tree Annotations ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 (define ast-weave-annotations
   (lambda (node type name value)
     (when (evaluator-state-in-evaluation? (node-evaluator-state node))
       (throw-exception
        "Cannot weave " name " annotation; "
        "There are attributes in evaluation."))
     (when (not (ast-annotation? node name))
       (cond
         ((and (not (node-list-node? node)) (not (node-bud-node? node)) (ast-subtype? node type))
          (ast-annotation-set! node name value))
         ((and (node-list-node? node) (eq? type 'list-node))
          (ast-annotation-set! node name value))
         ((and (node-bud-node? node) (eq? type 'bud-node))
          (ast-annotation-set! node name value))))
     (for-each
      (lambda (child)
        (unless (node-terminal? child)
          (ast-weave-annotations child type name value)))
      (node-children node))))
 
 (define ast-annotation?
   (lambda (node name)
     (when (evaluator-state-in-evaluation? (node-evaluator-state node))
       (throw-exception
        "Cannot check for " name " annotation; "
        "There are attributes in evaluation."))
     (assq name (node-annotations node))))
 
 (define ast-annotation
   (lambda (node name)
     (when (evaluator-state-in-evaluation? (node-evaluator-state node))
       (throw-exception
        "Cannot access " name " annotation; "
        "There are attributes in evaluation."))
     (let ((annotation (ast-annotation? node name)))
       (if annotation
           (cdr annotation)
           (throw-exception
            "Cannot access " name " annotation; "
            "The given node has no such annotation.")))))
 
 (define ast-annotation-set!
   (lambda (node name value)
     (when (evaluator-state-in-evaluation? (node-evaluator-state node))
       (throw-exception
        "Cannot set " name " annotation; "
        "There are attributes in evaluation."))
     (when (not (symbol? name))
       (throw-exception
        "Cannot set " name " annotation; "
        "Annotation names must be Scheme symbols."))
     (let ((annotation (ast-annotation? node name))
           (value
            (if (procedure? value)
                (lambda args
                  (apply value node args))
                value)))
       (if annotation
           (set-cdr! annotation value)
           (node-annotations-set! node (cons (cons name value) (node-annotations node)))))))
 
 (define ast-annotation-remove!
   (lambda (node name)
     (when (evaluator-state-in-evaluation? (node-evaluator-state node))
       (throw-exception
        "Cannot remove " name " annotation; "
        "There are attributes in evaluation."))
     (node-annotations-set!
      node
      (remp
       (lambda (entry)
         (eq? (car entry) name))
       (node-annotations node)))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Abstract Syntax Tree Specifications ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 (define specify-ast-rule
   (lambda (spec rule)
     ;;; Ensure, that the RACR system is in the correct specification phase:
     (when (> (racr-specification-specification-phase spec) 1)
       (throw-exception
        "Unexpected AST rule " rule "; "
        "AST rules can only be defined in the AST specification phase."))
     (letrec* ((rule-string (symbol->string rule)) ; String representation of the encoded rule (used for parsing)
               (pos 0) ; The current parsing position
               ; Support function returning, whether the end of the parsing string is reached or not:
               (eos?
                (lambda ()
                  (= pos (string-length rule-string))))
               ; Support function returning the current character to parse:
               (my-peek-char
                (lambda ()
                  (string-ref rule-string pos)))
               ; Support function returning the current character to parse and incrementing the parsing position:
               (my-read-char
                (lambda ()
                  (let ((c (my-peek-char)))
                    (set! pos (+ pos 1))
                    c)))
               ; Support function matching a certain character:
               (match-char!
                (lambda (c)
                  (if (eos?)
                      (throw-exception
                       "Unexpected end of AST rule " rule ";"
                       "Expected " c " character.")
                      (if (char=? (my-peek-char) c)
                          (set! pos (+ pos 1))
                          (throw-exception
                           "Invalid AST rule " rule "; "
                           "Unexpected " (my-peek-char) " character.")))))
               ; Support function parsing a symbol, i.e., retrieving its name, type, if it is a list and optional context-name.
               ; It returns a (name-as-scheme-symbol terminal? klenee? context-name-as-scheme-symbol?) quadrupel:
               (parse-symbol
                (lambda (location) ; location: l-hand, r-hand 
                  (let ((symbol-type (if (eq? location 'l-hand) "non-terminal" "terminal")))
                    (when (eos?)
                      (throw-exception
                       "Unexpected end of AST rule " rule "; "
                       "Expected " symbol-type "."))
                    (let* ((parse-name
                            (lambda (terminal?)
                              (let ((name
                                     (append
                                      (let loop ((chars (list)))
                                        (if (and (not (eos?)) (char-alphabetic? (my-peek-char)))
                                            (begin
                                              (when (and terminal? (not (char-lower-case? (my-peek-char))))
                                                (throw-exception
                                                 "Invalid AST rule " rule "; "
                                                 "Unexpected " (my-peek-char) " character."))
                                              (loop (cons (my-read-char) chars)))
                                            (reverse chars)))
                                      (let loop ((chars (list)))
                                        (if (and (not (eos?)) (char-numeric? (my-peek-char)))
                                            (loop (cons (my-read-char) chars))
                                            (reverse chars))))))
                                (when (null? name)
                                  (throw-exception
                                   "Unexpected " (my-peek-char) " character in AST rule " rule "; "
                                   "Expected " symbol-type "."))
                                (unless (char-alphabetic? (car name))
                                  (throw-exception
                                   "Malformed name in AST rule " rule "; "
                                   "Names must start with a letter."))
                                name)))
                           (terminal? (char-lower-case? (my-peek-char)))
                           (name (parse-name terminal?))
                           (klenee?
                            (and
                             (not terminal?)
                             (eq? location 'r-hand)
                             (not (eos?))
                             (char=? (my-peek-char) #\*)
                             (my-read-char)))
                           (context-name?
                            (and
                             (not terminal?)
                             (eq? location 'r-hand)
                             (not (eos?))
                             (char=? (my-peek-char) #\<)
                             (my-read-char)
                             (parse-name #f)))
                           (name-string (list->string name))
                           (name-symbol (string->symbol name-string)))
                      (when (and terminal? (eq? location 'l-hand))
                        (throw-exception
                         "Unexpected " name " terminal in AST rule " rule "; "
                         "Left hand side symbols must be non-terminals."))
                      (make-production-symbol
                       name-symbol
                       (not terminal?)
                       klenee?
                       (if context-name?
                           (string->symbol (list->string context-name?))
                           (if klenee?
                               (string->symbol (string-append name-string "*"))
                               name-symbol))
                       (list))))))
               (l-hand (parse-symbol 'l-hand)); The rule's l-hand
               (supertype ; The rule's super-type
                (and (not (eos?)) (char=? (my-peek-char) #\:) (my-read-char) (symbol-name (parse-symbol 'l-hand))))
               (rule* ; Representation of the parsed rule
                (begin
                  (match-char! #\-)
                  (match-char! #\>)
                  (make-ast-rule
                   spec
                   rule
                   (append
                    (list l-hand)
                    (let loop ((r-hand
                                (if (not (eos?))
                                    (list (parse-symbol 'r-hand))
                                    (list))))
                      (if (eos?)
                          (reverse r-hand)
                          (begin
                            (match-char! #\-)
                            (loop (cons (parse-symbol 'r-hand) r-hand))))))
                   supertype))))
              ; Check, that the rule's l-hand is not already defined:
              (when (racr-specification-find-rule spec (symbol-name l-hand))
                (throw-exception
                 "Invalid AST rule " rule "; "
                 "Redefinition of " (symbol-name l-hand) "."))
              (hashtable-set! ; Add the rule to the RACR system.
               (racr-specification-rules-table spec)
               (symbol-name l-hand)
               rule*))))
 
 (define compile-ast-specifications
   (lambda (spec start-symbol)
     ;;; Ensure, that the RACR system is in the correct specification phase and...
     (let ((current-phase (racr-specification-specification-phase spec)))
       (if (> current-phase 1)
           (throw-exception
            "Unexpected AST compilation; "
            "The AST specifications already have been compiled.")
           ; ...iff so proceed to the next specification phase:
           (racr-specification-specification-phase-set! spec (+ current-phase 1))))
     
     (racr-specification-start-symbol-set! spec start-symbol)
     (let* ((rules-list (racr-specification-rules-list spec))
            ; Support function, that given a rule R returns a list of all rules directly derivable from R:
            (derivable-rules
             (lambda (rule*)
               (fold-left
                (lambda (result symb*)
                  (if (symbol-non-terminal? symb*)
                      (append result (list (symbol-non-terminal? symb*)) (ast-rule-subtypes (symbol-non-terminal? symb*)))
                      result))
                (list)
                (cdr (ast-rule-production rule*))))))
       
       ;;; Resolve supertypes and non-terminals occuring in productions and ensure all non-terminals are defined:
       (for-each
        (lambda (rule*)
          (when (ast-rule-supertype? rule*)
            (let ((supertype-entry (racr-specification-find-rule spec (ast-rule-supertype? rule*))))
              (if (not supertype-entry)
                  (throw-exception
                   "Invalid AST rule " (ast-rule-as-symbol rule*) "; "
                   "The supertype " (ast-rule-supertype? rule*) " is not defined.")
                  (ast-rule-supertype?-set! rule* supertype-entry))))
          (for-each
           (lambda (symb*)
             (when (symbol-non-terminal? symb*)
               (let ((symb-definition (racr-specification-find-rule spec (symbol-name symb*))))
                 (when (not symb-definition)
                   (throw-exception
                    "Invalid AST rule " (ast-rule-as-symbol rule*) "; "
                    "Non-terminal " (symbol-name symb*) " is not defined."))
                 (symbol-non-terminal?-set! symb* symb-definition))))
           (cdr (ast-rule-production rule*))))
        rules-list)
       
       ;;; Ensure, that inheritance is cycle-free:
       (for-each
        (lambda (rule*)
          (when (memq rule* (ast-rule-subtypes rule*))
            (throw-exception
             "Invalid AST grammar; "
             "The definition of " (ast-rule-as-symbol rule*) " depends on itself (cyclic inheritance).")))
        rules-list)
       
       ;;; Ensure, that the start symbol is defined:
       (unless (racr-specification-find-rule spec start-symbol)
         (throw-exception
          "Invalid AST grammar; "
          "The start symbol " start-symbol " is not defined."))
       
       ;;; Ensure, that the start symbol has no super- and subtype:
       (let ((supertype (ast-rule-supertype? (racr-specification-find-rule spec start-symbol))))
         (when supertype
           (throw-exception
            "Invalid AST grammar; "
            "The start symbol " start-symbol " inherits from " (ast-rule-as-symbol supertype) ".")))
       (let ((subtypes (ast-rule-subtypes (racr-specification-find-rule spec start-symbol))))
         (unless (null? subtypes)
           (throw-exception
            "Invalid AST grammar; "
            "The rules " (map ast-rule-as-symbol subtypes) " inherit from the start symbol " start-symbol ".")))
       
       ;;; Ensure, that the CFG is start separated:
       (let ((start-rule (racr-specification-find-rule spec start-symbol)))
         (for-each
          (lambda (rule*)
            (when (memq start-rule (derivable-rules rule*))
              (throw-exception
               "Invalid AST grammar; "
               "The start symbol " start-symbol " is not start separated because of rule " (ast-rule-as-symbol rule*) ".")))
          rules-list))
       
       ;;; Resolve inherited production symbols:
       (apply-wrt-ast-inheritance
        (lambda (rule)
          (ast-rule-production-set!
           rule
           (append
            (list (car (ast-rule-production rule)))
            (map
             (lambda (symbol)
               (make-production-symbol
                (symbol-name symbol)
                (symbol-non-terminal? symbol)
                (symbol-kleene? symbol)
                (symbol-context-name symbol)
                (list)))
             (cdr (ast-rule-production (ast-rule-supertype? rule))))
            (cdr (ast-rule-production rule)))))
        rules-list)
       
       ;;; Ensure context-names are unique:
       (for-each
        (lambda (rule*)
          (let loop ((rest-production (cdr (ast-rule-production rule*))))
            (unless (null? rest-production)
              (let ((current-context-name (symbol-context-name (car rest-production))))
                (when (find
                       (lambda (symb*)
                         (eq? (symbol-context-name symb*) current-context-name))
                       (cdr rest-production))
                  (throw-exception
                   "Invalid AST grammar; "
                   "The context-name " current-context-name " is not unique for rule " (ast-rule-as-symbol rule*) "."))
                (loop (cdr rest-production))))))
        rules-list)
       
       ;;; Ensure, that all non-terminals can be derived from the start symbol:
       (let* ((to-check (list (racr-specification-find-rule spec start-symbol)))
              (checked (list)))
         (let loop ()
           (unless (null? to-check)
             (let ((rule* (car to-check)))
               (set! to-check (cdr to-check))
               (set! checked (cons rule* checked))
               (for-each
                (lambda (derivable-rule)
                  (when (and
                         (not (memq derivable-rule checked))
                         (not (memq derivable-rule to-check)))
                    (set! to-check (cons derivable-rule to-check))))
                (derivable-rules rule*))
               (loop))))
         (let ((non-derivable-rules
                (filter
                 (lambda (rule*)
                   (not (memq rule* checked)))
                 rules-list)))
           (unless (null? non-derivable-rules)
             (throw-exception
              "Invalid AST grammar; "
              "The rules " (map ast-rule-as-symbol non-derivable-rules) " cannot be derived."))))
       
       ;;; Ensure, that all non-terminals are productive:
       (let* ((productive-rules (list))
              (to-check rules-list)
              (productive-rule?
               (lambda (rule*)
                 (not (find
                       (lambda (symb*)
                         (and
                          (symbol-non-terminal? symb*)
                          (not (symbol-kleene? symb*)) ; Unbounded repetitions are always productive because of the empty list.
                          (not (memq (symbol-non-terminal? symb*) productive-rules))))
                       (cdr (ast-rule-production rule*)))))))
         (let loop ()
           (let ((productive-rule
                  (find productive-rule? to-check)))
             (when productive-rule
               (set! to-check (remq productive-rule to-check))
               (set! productive-rules (cons productive-rule productive-rules))
               (loop))))
         (unless (null? to-check)
           (throw-exception
            "Invalid AST grammar; "
            "The rules " (map ast-rule-as-symbol to-check) " are not productive."))))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Attribute Grammar Specifications ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 (define-syntax specify-ag-rule
   (lambda (x)
     (syntax-case x ()
       ((_ spec att-name definition ...)
        (and (identifier? #'att-name) (not (null? #'(definition ...))))
        #'(let ((spec* spec)
                (att-name* 'att-name))
            (let-syntax
                ((specify-attribute*
                  (syntax-rules ()
                    ((_ spec* att-name* ((non-terminal index) equation))
                     (specify-attribute spec* att-name* 'non-terminal 'index #t equation #f))
                    ((_ spec* att-name* ((non-terminal index) cached? equation))
                     (specify-attribute spec* att-name* 'non-terminal 'index cached? equation #f))
                    ((_ spec* att-name* ((non-terminal index) equation bottom equivalence-function))
                     (specify-attribute spec* att-name* 'non-terminal 'index #t equation (cons bottom equivalence-function)))
                    ((_ spec* att-name* ((non-terminal index) cached? equation bottom equivalence-function))
                     (specify-attribute spec* att-name* 'non-terminal 'index cached? equation (cons bottom equivalence-function)))
                    ((_ spec* att-name* (non-terminal equation))
                     (specify-attribute spec* att-name* 'non-terminal 0 #t equation #f))
                    ((_ spec* att-name* (non-terminal cached? equation))
                     (specify-attribute spec* att-name* 'non-terminal 0 cached? equation #f))
                    ((_ spec* att-name* (non-terminal equation bottom equivalence-function))
                     (specify-attribute spec* att-name* 'non-terminal 0 #t equation (cons bottom equivalence-function)))
                    ((_ spec* att-name* (non-terminal cached? equation bottom equivalence-function))
                     (specify-attribute spec* att-name* 'non-terminal 0 cached? equation (cons bottom equivalence-function))))))
              (specify-attribute* spec* att-name* definition) ...))))))
 
 (define specify-attribute
   (lambda (spec attribute-name non-terminal context-name-or-position cached? equation circularity-definition)
     ;;; Before adding the attribute definition, ensure...
     (let ((wrong-argument-type ; ...correct argument types,...
            (or
             (and (not (symbol? attribute-name))
                  "Attribute name : symbol")
             (and (not (symbol? non-terminal))
                  "AST rule : non-terminal")
             (and (not (symbol? context-name-or-position))
                  (or (not (integer? context-name-or-position)) (< context-name-or-position 0))
                  "Production position : index or context-name")
             (and (not (procedure? equation))
                  "Attribute equation : function")
             (and circularity-definition
                  (not (pair? circularity-definition))
                  (not (procedure? (cdr circularity-definition)))
                  "Circularity definition : #f or (bottom-value equivalence-function) pair"))))
       (when wrong-argument-type
         (throw-exception
          "Invalid attribute definition; "
          "Wrong argument type (" wrong-argument-type ").")))
     (unless (= (racr-specification-specification-phase spec) 2) ; ...that the RACR system is in the correct specification phase,...
       (throw-exception
        "Unexpected " attribute-name " attribute definition; "
        "Attributes can only be defined in the AG specification phase."))
     (let ((ast-rule (racr-specification-find-rule spec non-terminal)))
       (unless ast-rule ; ...the given AST rule is defined,...
         (throw-exception
          "Invalid attribute definition; "
          "The non-terminal " non-terminal " is not defined."))
       (let* ((position ; ...the given context exists,...
               (if (symbol? context-name-or-position)
                   (if (eq? context-name-or-position '*)
                       0
                       (let loop ((pos 1)
                                  (rest-production (cdr (ast-rule-production ast-rule))))
                         (if (null? rest-production)
                             (throw-exception
                              "Invalid attribute definition; "
                              "The non-terminal " non-terminal " has no " context-name-or-position " context.")
                             (if (eq? (symbol-context-name (car rest-production)) context-name-or-position)
                                 pos
                                 (loop (+ pos 1) (cdr rest-production))))))
                   (if (>= context-name-or-position (length (ast-rule-production ast-rule)))
                       (throw-exception
                        "Invalid attribute definition; "
                        "There exists no " context-name-or-position "'th position in the context of " non-terminal ".")
                       context-name-or-position)))
              (context (list-ref (ast-rule-production ast-rule) position)))
         (unless (symbol-non-terminal? context) ; ...it is a non-terminal and...
           (throw-exception
            "Invalid attribute definition; "
            non-terminal context-name-or-position " is a terminal."))
         ; ...the attribute is not already defined for it:
         (when (memq attribute-name (map attribute-definition-name (symbol-attributes context)))
           (throw-exception
            "Invalid attribute definition; "
            "Redefinition of " attribute-name " for " non-terminal context-name-or-position "."))
         ;;; Everything is fine. Thus, add the definition to the AST rule's respective symbol:
         (symbol-attributes-set!
          context
          (cons
           (make-attribute-definition
            attribute-name
            (cons ast-rule position)
            equation
            circularity-definition
            cached?)
           (symbol-attributes context)))))))
 
 (define compile-ag-specifications
   (lambda (spec)
     ;;; Ensure, that the RACR system is in the correct specification phase and...
     (let ((current-phase (racr-specification-specification-phase spec)))
       (when (< current-phase 2)
         (throw-exception
          "Unexpected AG compilation; "
          "The AST specifications are not yet compiled."))
       (if (> current-phase 2)
           (throw-exception
            "Unexpected AG compilation; "
            "The AG specifications already have been compiled.")
           (racr-specification-specification-phase-set! spec (+ current-phase 1)))) ; ...if so proceed to the next specification phase.
     
     ;;; Resolve attribute definitions inherited from a supertype. Thus,...
     (apply-wrt-ast-inheritance ; ...for every AST rule R which has a supertype...
      (lambda (rule)
        (let loop ((super-prod (ast-rule-production (ast-rule-supertype? rule)))
                   (sub-prod (ast-rule-production rule)))
          (unless (null? super-prod)
            (for-each ; ...check for every attribute definition of R's supertype...
             (lambda (super-att-def)
               (unless (find ; ...if it is shadowed by an attribute definition of R....
                        (lambda (sub-att-def)
                          (eq? (attribute-definition-name sub-att-def) (attribute-definition-name super-att-def)))
                        (symbol-attributes (car sub-prod)))
                 (symbol-attributes-set! ; ...If not, add...
                  (car sub-prod)
                  (cons
                   (make-attribute-definition ; ...a copy of the attribute definition inherited...
                    (attribute-definition-name super-att-def)
                    (cons rule (cdr (attribute-definition-context super-att-def))) ; ...to R.
                    (attribute-definition-equation super-att-def)
                    (attribute-definition-circularity-definition super-att-def)
                    (attribute-definition-cached? super-att-def))
                   (symbol-attributes (car sub-prod))))))
             (symbol-attributes (car super-prod)))
            (loop (cdr super-prod) (cdr sub-prod)))))
      (racr-specification-rules-list spec))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Attribute Evaluator ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 ; INTERNAL FUNCTION: Given a node n find a certain attribute associated with it, whereas in case no proper
 ; attribute is associated with n itself the search is extended to find a broadcast solution. Iff the
 ; extended search finds a solution, appropriate copy propergation attributes (i.e., broadcasters) are added.
 ; Iff no attribute instance can be found or n is a bud node, an exception is thrown. Otherwise, the
 ; attribute or its respective last broadcaster is returned.
 (define lookup-attribute
   (lambda (name n)
     (when (node-bud-node? n)
       (throw-exception
        "AG evaluator exception; "
        "Cannot access " name " attribute - the given node is a bud."))
     (let loop ((n n)) ; Recursively...
       (let ((att (node-find-attribute n name))) ; ...check if the current node has a proper attribute instance....
         (if att
             att ; ...Iff it has, return the found defining attribute instance.
             (let ((parent (node-parent n))) ; ...Iff no defining attribute instance can be found...
               (if (not parent) ; ...check if there exists a parent node that may provide a definition....
                   (throw-exception ; ...Iff not, throw an exception,...
                    "AG evaluator exception; "
                    "Cannot access unknown " name " attribute.")
                   (let* ((att (loop parent)) ; ...otherwise proceed the search at the parent node. Iff it succeeds...
                          (broadcaster ; ...construct a broadcasting attribute instance...
                           (make-attribute-instance
                            (make-attribute-definition ; ...whose definition context depends...
                             name
                             (if (eq? (node-ast-rule parent) 'list-node) ; ...if the parent node is a list-node or not....
                                 (cons ; ...Iff it is a list-node the broadcaster's context is...
                                  (node-ast-rule (node-parent parent)) ; ...the list-node's parent node and...
                                  (node-child-index parent)) ; ...child position.
                                 (cons ; ...Iff the parent node is not a list-node the broadcaster's context is...
                                  (node-ast-rule parent) ; ...the parent node and...
                                  (node-child-index n))) ; ...the current node's child position. Further,...
                             (lambda (n . args) ; ...the broadcaster's equation just calls the parent node's counterpart. Finally,...
                               (apply att-value name (ast-parent n) args))
                             (attribute-definition-circularity-definition (attribute-instance-definition att))
                             #f)
                            n)))
                     (node-attributes-set! n (cons broadcaster (node-attributes n))) ; ...add the constructed broadcaster and...
                     broadcaster)))))))) ; ...return it as the current node's look-up result.
 
 (define att-value
   (lambda (name n . args)
     (let*-values (; The evaluator state used and changed throughout evaluation:
                   ((evaluator-state) (values (node-evaluator-state n)))
                   ; The attribute instance to evaluate:
                   ((att) (values (lookup-attribute name n)))
                   ; The attribute's definition:
                   ((att-def) (values (attribute-instance-definition att)))
                   ; The attribute cache entries used for evaluation and dependency tracking:
                   ((evaluation-att-cache dependency-att-cache)
                    (if (attribute-definition-cached? att-def)
                        ; If the attribute instance is cached, no special action is required, except...
                        (let ((att-cache
                               (or
                                ; ...finding the attribute cache entry to use...
                                (hashtable-ref (attribute-instance-cache att) args #f)
                                ; ...or construct a respective one.
                                (let ((new-entry (make-attribute-cache-entry att args)))
                                  (hashtable-set! (attribute-instance-cache att) args new-entry)
                                  new-entry))))
                          (values att-cache att-cache))
                        ; If the attribute is not cached, special attention must be paid to avoid the permament storing
                        ; of fixpoint results and attribute arguments on the one hand but still retaining correct
                        ; evaluation which requires these information on the other hand. To do so we introduce two
                        ; different types of attribute cache entries:
                        ; (1) A parameter approximating entry for tracking dependencies and influences of the uncached
                        ;     attribute instance.
                        ; (2) A set of temporary cycle entries for correct cycle detection and fixpoint computation.
                        ; The "cycle-value" field of the parameter approximating entry is misused to store the hashtable
                        ; containing the temporary cycle entries and must be deleted when evaluation finished.
                        (let* ((dependency-att-cache
                                (or
                                 (hashtable-ref (attribute-instance-cache att) racr-nil #f)
                                 (let ((new-entry (make-attribute-cache-entry att racr-nil)))
                                   (hashtable-set! (attribute-instance-cache att) racr-nil new-entry)
                                   (attribute-cache-entry-cycle-value-set!
                                    new-entry
                                    (make-hashtable equal-hash equal? 1))
                                   new-entry)))
                               (evaluation-att-cache
                                (or
                                 (hashtable-ref (attribute-cache-entry-cycle-value dependency-att-cache) args #f)
                                 (let ((new-entry (make-attribute-cache-entry att args)))
                                   (hashtable-set!
                                    (attribute-cache-entry-cycle-value dependency-att-cache)
                                    args
                                    new-entry)
                                   new-entry))))
                          (values evaluation-att-cache dependency-att-cache))))
                   ; Support function that given an intermediate fixpoint result checks if it is different from the
                   ; current cycle value and updates the cycle value and evaluator state accordingly:
                   ((update-cycle-cache)
                    (values
                     (lambda (new-result)
                       (unless ((cdr (attribute-definition-circularity-definition att-def))
                                new-result
                                (attribute-cache-entry-cycle-value evaluation-att-cache))
                         (attribute-cache-entry-cycle-value-set! evaluation-att-cache new-result)
                         (evaluator-state-ag-cycle-change?-set! evaluator-state #t))))))
       ; Decide how to evaluate the attribute dependening on whether its value already is cached or its respective
       ; cache entry is circular, already in evaluation or starting point of a fix-point computation:
       (cond
         ; CASE (0): Attribute already evaluated for given arguments:
         ((not (eq? (attribute-cache-entry-value evaluation-att-cache) racr-nil))
          ; Maintaine attribute cache entry dependencies, i.e., if this entry is evaluated throughout the
          ; evaluation of another entry, the other entry depends on this one. Afterwards,...
          (add-dependency:cache->cache dependency-att-cache)
          (attribute-cache-entry-value evaluation-att-cache)) ; ...return the cached value.
         
         ; CASE (1): Circular attribute that is starting point of a fixpoint computation:
         ((and (attribute-definition-circular? att-def) (not (evaluator-state-ag-in-cycle? evaluator-state)))
          (dynamic-wind
           (lambda ()
             ; Maintaine attribute cache entry dependencies, i.e., if this entry is evaluated throughout the
             ; evaluation of another entry, the other depends on this one. Further this entry depends
             ; on any other entry that will be evaluated through its own evaluation. Further,..
             (add-dependency:cache->cache dependency-att-cache)
             (evaluator-state-evaluation-stack-set!
              evaluator-state
              (cons dependency-att-cache (evaluator-state-evaluation-stack evaluator-state)))
             ; ...mark, that the entry is in evaluation and...
             (attribute-cache-entry-entered?-set! evaluation-att-cache #t)
             ; ...update the evaluator's state that we are about to start a fix-point computation.
             (evaluator-state-ag-in-cycle?-set! evaluator-state #t))
           (lambda ()
             (let loop () ; Start fix-point computation. Thus, as long as...
               (evaluator-state-ag-cycle-change?-set! evaluator-state #f) ; ...an entry's value changes...
               (update-cycle-cache (apply (attribute-definition-equation att-def) n args)) ; ...evaluate this entry.
               (when (evaluator-state-ag-cycle-change? evaluator-state)
                 (loop)))
             (let ((result (attribute-cache-entry-cycle-value evaluation-att-cache)))
               ; When fixpoint computation finished update the caches of all circular entries evaluated. To do so,...
               (let loop ((att-cache
                           (if (attribute-definition-cached? att-def)
                               evaluation-att-cache
                               dependency-att-cache)))
                 (let ((att-def (attribute-instance-definition (attribute-cache-entry-context att-cache))))
                   (if (not (attribute-definition-circular? att-def))
                       ; ...ignore non-circular entries and just proceed with the entries they depend on (to
                       ; ensure all strongly connected components within a weakly connected one are updated)....
                       (for-each
                        loop
                        (attribute-cache-entry-cache-dependencies att-cache))
                       ; ...In case of circular entries...
                       (if (attribute-definition-cached? att-def) ; ...check if they have to be cached and...
                           (when (eq? (attribute-cache-entry-value att-cache) racr-nil) ; ...are not already processed....
                             ; ...If so cache them,...
                             (attribute-cache-entry-value-set!
                              att-cache
                              (attribute-cache-entry-cycle-value att-cache))
                             (attribute-cache-entry-cycle-value-set! ; ...reset their cycle values to the bottom value and...
                              att-cache
                              (car (attribute-definition-circularity-definition att-def)))
                             (for-each ; ...proceed with the entries they depend on.
                              loop
                              (attribute-cache-entry-cache-dependencies att-cache)))
                           ; ...If a circular entry is not cached, check if it already is processed....
                           (when (> (hashtable-size (attribute-cache-entry-cycle-value att-cache)) 0)
                             ; ...If not, delete its temporary cycle cache and...
                             (hashtable-clear! (attribute-cache-entry-cycle-value att-cache))
                             (for-each ; ...proceed with the entries it depends on.
                              loop
                              (attribute-cache-entry-cache-dependencies att-cache)))))))
               result))
           (lambda ()
             ; Mark that fixpoint computation finished,...
             (evaluator-state-ag-in-cycle?-set! evaluator-state #f)
             ; the evaluation of the attribute cache entry finished and...
             (attribute-cache-entry-entered?-set! evaluation-att-cache #f)
             ; ...pop the entry from the evaluation stack.
             (evaluator-state-evaluation-stack-set!
              evaluator-state
              (cdr (evaluator-state-evaluation-stack evaluator-state))))))
         
         ; CASE (2): Circular attribute already in evaluation for the given arguments:
         ((and (attribute-definition-circular? att-def) (attribute-cache-entry-entered? evaluation-att-cache))
          ; Maintaine attribute cache entry dependencies, i.e., if this entry is evaluated throughout the
          ; evaluation of another entry, the other entry depends on this one. Finally,...
          (add-dependency:cache->cache dependency-att-cache)
          ; ...the intermediate fixpoint result is the attribute cache entry's cycle value.
          (attribute-cache-entry-cycle-value evaluation-att-cache))
         
         ; CASE (3): Circular attribute not in evaluation and entered throughout a fixpoint computation:
         ((attribute-definition-circular? att-def)
          (dynamic-wind
           (lambda ()
             ; Maintaine attribute cache entry dependencies, i.e., if this entry is evaluated throughout the
             ; evaluation of another entry, the other depends on this one. Further this entry depends
             ; on any other entry that will be evaluated through its own evaluation. Further,..
             (add-dependency:cache->cache dependency-att-cache)
             (evaluator-state-evaluation-stack-set!
              evaluator-state
              (cons dependency-att-cache (evaluator-state-evaluation-stack evaluator-state)))
             ; ...mark, that the entry is in evaluation.
             (attribute-cache-entry-entered?-set! evaluation-att-cache #t))
           (lambda ()
             (let ((result (apply (attribute-definition-equation att-def) n args))) ; Evaluate the entry and...
               (update-cycle-cache result) ; ...update its cycle value.
               result))
           (lambda ()
             ; Mark that the evaluation of the attribute cache entry finished and...
             (attribute-cache-entry-entered?-set! evaluation-att-cache #f)
             ; ...pop it from the evaluation stack.
             (evaluator-state-evaluation-stack-set!
              evaluator-state
              (cdr (evaluator-state-evaluation-stack evaluator-state))))))
         
         ; CASE (4): Non-circular attribute already in evaluation, i.e., unexpected cycle:
         ((attribute-cache-entry-entered? evaluation-att-cache)
          ; Maintaine attribute cache entry dependencies, i.e., if this entry is evaluated throughout the
          ; evaluation of another entry, the other entry depends on this one. Then,...
          (add-dependency:cache->cache dependency-att-cache)
          (throw-exception ; ...thrown an exception because we encountered an unexpected dependency cycle.
           "AG evaluator exception; "
           "Unexpected " name " cycle."))
         
         (else ; CASE (5): Non-circular attribute not in evaluation:
          (dynamic-wind
           (lambda ()
             ; Maintaine attribute cache entry dependencies, i.e., if this entry is evaluated throughout the
             ; evaluation of another entry, the other depends on this one. Further this entry depends
             ; on any other entry that will be evaluated through its own evaluation. Further,...
             (add-dependency:cache->cache dependency-att-cache)
             (evaluator-state-evaluation-stack-set!
              evaluator-state
              (cons dependency-att-cache (evaluator-state-evaluation-stack evaluator-state)))
             ; ...mark, that the entry is in evaluation.
             (attribute-cache-entry-entered?-set! evaluation-att-cache #t))
           (lambda ()
             (let ((result (apply (attribute-definition-equation att-def) n args))) ; Evaluate the entry and,...
               (when (attribute-definition-cached? att-def) ; ...if caching is enabled,...
                 (attribute-cache-entry-value-set! evaluation-att-cache result)) ; ...cache its value.
               result))
           (lambda ()
             ; Mark that the evaluation of the attribute cache entry finished and...
             (if (attribute-definition-cached? att-def)
                 (attribute-cache-entry-entered?-set! evaluation-att-cache #f)
                 (hashtable-delete! (attribute-cache-entry-cycle-value dependency-att-cache) args))
             ; ...pop it from the evaluation stack.
             (evaluator-state-evaluation-stack-set!
              evaluator-state
              (cdr (evaluator-state-evaluation-stack evaluator-state))))))))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Abstract Syntax Tree Access Interface ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 (define ast-node-type
   (lambda (n)
     (when (or (node-list-node? n) (node-bud-node? n)) ; Remember: (node-terminal? n) is not possible
       (throw-exception
        "Cannot access type; "
        "List and bud nodes have no type."))
     (add-dependency:cache->node-type n)
     (symbol-name (car (ast-rule-production (node-ast-rule n))))))
 
 (define ast-list-node?
   (lambda (n)
     (if (node-bud-node? n)
         (throw-exception
          "Cannot perform list node check; "
          "Bud nodes have no type.")
         (node-list-node? n))))
 
 (define ast-subtype?
   (lambda (a1 a2)
     (when (or
            (and (node? a1) (or (node-list-node? a1) (node-bud-node? a1)))
            (and (node? a2) (or (node-list-node? a2) (node-bud-node? a2))))
       (throw-exception
        "Cannot perform subtype check; "
        "List and bud nodes cannot be tested for subtyping."))
     (when (and (not (node? a1)) (not (node? a2)))
       (throw-exception
        "Cannot perform subtype check; "
        "At least one argument must be an AST node."))
     ((lambda (t1/t2)
        (and
         (car t1/t2)
         (cdr t1/t2)
         (ast-rule-subtype? (car t1/t2) (cdr t1/t2))))
      (if (symbol? a1)
          (let* ((t2 (node-ast-rule a2))
                 (t1 (racr-specification-find-rule (ast-rule-specification t2) a1)))
            (unless t1
              (throw-exception
               "Cannot perform subtype check; "
               a1 " is no valid non-terminal (first argument undefined non-terminal)."))
            (add-dependency:cache->node-super-type a2 t1)
            (cons t1 t2))
          (if (symbol? a2)
              (let* ((t1 (node-ast-rule a1))
                     (t2 (racr-specification-find-rule (ast-rule-specification t1) a2)))
                (unless t1
                  (throw-exception
                   "Cannot perform subtype check; "
                   a2 " is no valid non-terminal (second argument undefined non-terminal)."))
                (add-dependency:cache->node-sub-type a1 t2)
                (cons t1 t2))
              (begin
                (add-dependency:cache->node-sub-type a1 (node-ast-rule a2))
                (add-dependency:cache->node-super-type a2 (node-ast-rule a1))
                (cons (node-ast-rule a1) (node-ast-rule a2))))))))
 
 (define ast-parent
   (lambda (n)
     (let ((parent (node-parent n)))
       (unless parent
         (throw-exception "Cannot access parent of roots."))
       (add-dependency:cache->node parent)
       parent)))
 
 (define ast-child
   (lambda (i n)
     (let ((child
            (if (symbol? i)
                (node-find-child n i)
                (and (>= i 1) (<= i (length (node-children n))) (list-ref (node-children n) (- i 1))))))
       (unless child
         (throw-exception "Cannot access non-existent " i (if (symbol? i) "'th" "") " child."))
       (add-dependency:cache->node child)
       (if (node-terminal? child)
           (node-children child)
           child))))
 
 (define ast-sibling
   (lambda (i n)
     (ast-child i (ast-parent n))))
 
 (define ast-child-index
   (lambda (n)
     (add-dependency:cache->node n)
     (node-child-index n)))
 
 (define ast-num-children
   (lambda (n)
     (when (node-bud-node? n)
       (throw-exception
        "Cannot access number of children; "
        "Bud nodes have no children."))
     (add-dependency:cache->node-num-children n)
     (length (node-children n))))
 
 (define-syntax ast-children
   (syntax-rules ()
     ((_ n b ...)
      (reverse
       (let ((result (list)))
         (ast-for-each-child
          (lambda (i child)
            (set! result (cons child result)))
          n
          b ...)
         result)))))
 
 (define-syntax ast-for-each-child
   (syntax-rules ()
     ((_ f n b)
      (let* ((f* f)
             (n* n)
             (b* b)
             (ub (cdr b*)))
        (when (node-bud-node? n*)
          (throw-exception
           "Cannot visit children; "
           "No valid operation on bud nodes."))
        (if (eq? ub '*)
            (let ((pos (car b*))
                  (ub (length (node-children n*))))
              (dynamic-wind
               (lambda () #f)
               (lambda ()
                 (let loop ()
                   (when (<= pos ub)
                     (f* pos (ast-child pos n*))
                     (set! pos (+ pos 1))
                     (loop))))
               (lambda ()
                 (when (> pos ub)
                   (ast-num-children n*))))) ; BEWARE: Access to number of children ensures proper dependency tracking!
            (let loop ((pos (car b*)))
              (when (<= pos ub)
                (f* pos (ast-child pos n*))
                (loop (+ pos 1)))))))
     ((_ f n)
      (ast-for-each-child f n (cons 1 '*)))
     ((_ f n b ...)
      (let ((f* f)
            (n* n))
        (ast-for-each-child f* n* b) ...))))
 
 (define-syntax ast-find-child
   (syntax-rules ()
     ((_ f n b ...)
      (let ((f* f))
        (call/cc
         (lambda (c)
           (ast-for-each-child
            (lambda (i child)
              (when (f* i child)
                (c child)))
            n
            b ...)
           #f))))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Abstract Syntax Tree Construction Interface ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 (define create-ast
   (lambda (spec rule children)
     ;;; Ensure, that the RACR system is completely specified:
     (when (< (racr-specification-specification-phase spec) 3)
       (throw-exception
        "Cannot construct " rule " fragment; "
        "The RACR specification still must be compiled."))
     
     (let ((ast-rule* (racr-specification-find-rule spec rule)))
       ;;; Ensure, that the given AST rule is defined:
       (unless ast-rule*
         (throw-exception
          "Cannot construct " rule " fragment; "
          "Unknown non-terminal/rule."))
       
       ;;; Ensure, that the expected number of children are given:
       (unless (= (length children) (- (length (ast-rule-production ast-rule*)) 1))
         (throw-exception
          "Cannot construct " rule " fragment; "
          (length children) " children given, but " (- (length (ast-rule-production ast-rule*)) 1) " children expected."))
       
       ;;; Construct the fragment, i.e., (1) the AST part consisting of the root and the given children and (2) the root's
       ;;; synthesized attribute instances and the childrens' inherited ones.
       (let (;;; For (1) - the construction of the fragment's AST part - first construct the fragment's root. Then...
             (root
              (make-node
               ast-rule*
               #f
               (list))))
         (node-children-set! ; ...ensure, that the given children fit and add them to the fragment to construct. Therefore,...
          root
          (let loop ((pos 1) ; ...investigate every...
                     (symbols (cdr (ast-rule-production ast-rule*))) ; ...expected and...
                     (children children)) ; ...given child....
            (if (null? symbols) ; ...If no further child is expected,...
                (list) ; ...we are done, otherwise...
                (let ((symb* (car symbols))
                      (child (car children)))
                  (if (symbol-non-terminal? symb*) ; ...check if the next expected child is a non-terminal....
                      (let ((ensure-child-fits ; ...If we expect a non-terminal we need a function which ensures, that...
                             (lambda (child)
                               ; ...the child either is a bud-node or its type is the one of the
                               ; expected non-terminal or a sub-type....
                               (unless (or
                                        (node-bud-node? child)
                                        (ast-rule-subtype? (node-ast-rule child) (symbol-non-terminal? symb*)))
                                 (throw-exception
                                  "Cannot construct " rule " fragment; "
                                  "Expected a " (symbol-name symb*) " node as " pos "'th child, not a " (ast-node-type child) ".")))))
                        (unless (node? child) ; ...Then, check that the given child is an AST node,...
                          (throw-exception
                           "Cannot construct " rule " fragment; "
                           "Expected a " (symbol-name symb*) " node as " pos "'th child, not a terminal."))
                        (when (node-parent child) ; ...does not already belong to another AST and...
                          (throw-exception
                           "Cannot construct " rule " fragment; "
                           "The given " pos "'th child already is part of another AST fragment."))
                        ; ...non of its attributes are in evaluation....
                        (when (evaluator-state-in-evaluation? (node-evaluator-state child))
                          (throw-exception
                           "Cannot construct " rule " fragment; "
                           "There are attributes in evaluation."))
                        (if (symbol-kleene? symb*) ; ...Now, check if we expect a list of non-terminals...
                            (if (node-list-node? child) ; ...If we expect a list, ensure the given child is a list-node and...
                                (for-each ensure-child-fits (node-children child)) ; ...all its elements fit....
                                (throw-exception
                                 "Cannot construct " rule " fragment; "
                                 "Expected a list-node as " pos "'th child, not a "
                                 (if (node? child)
                                     (string-append "single [" (symbol->string (ast-node-type child)) "] node")
                                     "terminal")
                                 "."))
                            (ensure-child-fits child)) ; ...If we expect a single non-terminal child, just ensure that the child fits....
                        (node-parent-set! child root) ; ...Finally, set the root as the child's parent,...
                        (cons
                         child ; ...add the child to the root's children and...
                         (loop (+ pos 1) (cdr symbols) (cdr children)))) ; ...process the next expected child.
                      (cons ; If we expect a terminal,...
                       (make-node ; ...add a terminal node encapsulating the given value to the root's children and...
                        'terminal
                        root
                        child)
                       (loop (+ pos 1) (cdr symbols) (cdr children)))))))) ; ...process the next expected child.
         ; ...When all children are processed, distribute the new fragment's evaluator state:
         (distribute-evaluator-state (make-evaluator-state) root)
         
         ;;; The AST part of the fragment is properly constructed so we can proceed with (2) - the construction
         ;;; of the fragment's attribute instances. Therefore,...
         (update-synthesized-attribution root) ; ...initialize the root's synthesized and...
         (for-each ; ...each child's inherited attributes.
          update-inherited-attribution
          (node-children root))
         
         root)))) ; Finally, return the newly constructed fragment.
 
 (define create-ast-list
   (lambda (children)
     (let* ((child-with-spec
             (find
              (lambda (child)
                (and (node? child) (not (node-list-node? child)) (not (node-bud-node? child))))
              children))
            (spec (and child-with-spec (ast-rule-specification (node-ast-rule child-with-spec)))))
       (let loop ((children children) ; For every child, ensure, that the child is a...
                  (pos 1))
         (unless (null? children)
           (when (or (not (node? (car children))) (node-list-node? (car children))) ; ...proper non-terminal node,...
             (throw-exception
              "Cannot construct list-node; "
              "The given " pos "'th child is not a non-terminal, non-list node."))
           (when (node-parent (car children)) ; ...is not already part of another AST,...
             (throw-exception
              "Cannot construct list-node; "
              "The given " pos "'th child already is part of another AST."))
           ; ...non of its attributes are in evaluation and...
           (when (evaluator-state-in-evaluation? (node-evaluator-state (car children)))
             (throw-exception
              "Cannot construct list-node; "
              "The given " pos "'th child has attributes in evaluation."))
           (unless (or ; ...all children are instances of the same RACR specification.
                    (node-bud-node? (car children))
                    (eq? (ast-rule-specification (node-ast-rule (car children)))
                         spec))
             (throw-exception
              "Cannot construct list-node; "
              "The given children are instances of different RACR specifications."))
           (loop (cdr children) (+ pos 1)))))
     (let ((list-node ; ...Finally, construct the list-node,...
            (make-node
             'list-node
             #f
             children)))
       (for-each ; ...set it as parent for every of its elements,...
        (lambda (child)
          (node-parent-set! child list-node))
        children)
       (distribute-evaluator-state (make-evaluator-state) list-node) ; ...construct and distribute its evaluator state and...
       list-node))) ; ...return it.
 
 (define create-ast-bud
   (lambda ()
     (let ((bud-node (make-node 'bud-node #f (list))))
       (distribute-evaluator-state (make-evaluator-state) bud-node)
       bud-node)))
 
 (define create-ast-mockup
   (lambda (rule)
     (create-ast
      (ast-rule-specification rule)
      (symbol-name (car (ast-rule-production rule)))
      (map
       (lambda (symbol)
         (cond
           ((not (symbol-non-terminal? symbol))
            racr-nil)
           ((symbol-kleene? symbol)
            (create-ast-list (list)))
           (else (create-ast-bud))))
       (cdr (ast-rule-production rule))))))
 
 ; INTERNAL FUNCTION: Given an AST node update its synthesized attribution (i.e., add missing synthesized
 ; attributes, delete superfluous ones, shadow equally named inherited attributes and update the
 ; definitions of existing synthesized attributes.
 (define update-synthesized-attribution
   (lambda (n)
     (when (and (not (node-terminal? n)) (not (node-list-node? n)) (not (node-bud-node? n)))
       (for-each
        (lambda (att-def)
          (let ((att (node-find-attribute n (attribute-definition-name att-def))))
            (cond
              ((not att)
               (node-attributes-set! n (cons (make-attribute-instance att-def n) (node-attributes n))))
              ((eq? (attribute-definition-equation (attribute-instance-definition att)) (attribute-definition-equation att-def))
               (attribute-instance-definition-set! att att-def))
              (else
               (flush-attribute-instance att)
               (node-attributes-set!
                n
                (cons (make-attribute-instance att-def n) (remq att (node-attributes n))))))))
        (symbol-attributes (car (ast-rule-production (node-ast-rule n)))))
       (node-attributes-set! ; Delete all synthesized attribute instances not defined anymore:
        n
        (remp
         (lambda (att)
           (let ((remove?
                  (and
                   (attribute-definition-synthesized? (attribute-instance-definition att))
                   (not (eq? (car (attribute-definition-context (attribute-instance-definition att))) (node-ast-rule n))))))
             (when remove?
               (flush-attribute-instance att))
             remove?))
         (node-attributes n))))))
 
 ; INTERNAL FUNCTION: Given an AST node update its inherited attribution (i.e., add missing inherited
 ; attributes, delete superfluous ones and update the definitions of existing inherited attributes.
 ; If the given node is a list-node the inherited attributes of its elements are updated.
 (define update-inherited-attribution
   (lambda (n)
     ;;; Support function updating n's inherited attribution w.r.t. a list of inherited attribute definitions:
     (define update-by-defs
       (lambda (n att-defs)
         (for-each ; Add new and update existing inherited attribute instances:
          (lambda (att-def)
            (let ((att (node-find-attribute n (attribute-definition-name att-def))))
              (cond
                ((not att)
                 (node-attributes-set! n (cons (make-attribute-instance att-def n) (node-attributes n))))
                ((not (attribute-definition-synthesized? (attribute-instance-definition att)))
                 (if (eq?
                      (attribute-definition-equation (attribute-instance-definition att))
                      (attribute-definition-equation att-def))
                     (attribute-instance-definition-set! att att-def)
                     (begin
                       (flush-attribute-instance att)
                       (node-attributes-set!
                        n
                        (cons (make-attribute-instance att-def n) (remq att (node-attributes n))))))))))
          att-defs)
         (node-attributes-set! ; Delete all inherited attribute instances not defined anymore:
          n
          (remp
           (lambda (att)
             (let ((remove?
                    (and
                     (attribute-definition-inherited? (attribute-instance-definition att))
                     (not (memq (attribute-instance-definition att) att-defs)))))
               (when remove?
                 (flush-attribute-instance att))
               remove?))
           (node-attributes n)))))
     ;;; Perform the update:
     (let* ((n* (if (node-list-node? (node-parent n)) (node-parent n) n))
            (att-defs (symbol-attributes (list-ref (ast-rule-production (node-ast-rule (node-parent n*))) (node-child-index n*)))))
       (if (node-list-node? n)
           (for-each
            (lambda (n)
              (unless (node-bud-node? n)
                (update-by-defs n att-defs)))
            (node-children n))
           (unless (node-bud-node? n)
             (update-by-defs n att-defs))))))
 
 ; INTERNAL FUNCTION: Given an AST node delete its inherited attribute instances. Iff the given node
 ; is a list node, the inherited attributes of its elements are deleted.
 (define detach-inherited-attributes
   (lambda (n)
     (cond
       ((node-list-node? n)
        (for-each
         detach-inherited-attributes
         (node-children n)))
       ((node-non-terminal? n)
        (node-attributes-set!
         n
         (remp
          (lambda (att)
            (let ((remove? (attribute-definition-inherited? (attribute-instance-definition att))))
              (when remove?
                (flush-attribute-instance att))
              remove?))
          (node-attributes n)))))))
 
 ; INTERNAL FUNCTION: Given an evaluator state and an AST fragment, change the
 ; fragment's evaluator state to the given one.
 (define distribute-evaluator-state
   (lambda (evaluator-state n)
     (node-evaluator-state-set! n evaluator-state)
     (unless (node-terminal? n)
       (for-each
        (lambda (n)
          (distribute-evaluator-state evaluator-state n))
        (node-children n)))))
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Rewrite Interface ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 (define perform-rewrites
   (lambda (n strategy . transformers)
     (define find-and-apply
       (case strategy
         ((top-down)
          (lambda (n)
            (and
             (not (node-terminal? n))
             (or
              (find (lambda (r) (r n)) transformers)
              (find find-and-apply (node-children n))))))
         ((bottom-up)
          (lambda (n)
            (and
             (not (node-terminal? n))
             (or
              (find find-and-apply (node-children n))
              (find (lambda (r) (r n)) transformers)))))
         (else (throw-exception
                "Cannot perform rewrites; "
                "Unknown " strategy " strategy."))))
     (let loop ()
       (when (node-parent n)
         (throw-exception
          "Cannot perform rewrites; "
          "The given starting point is not (anymore) an AST root."))
       (let ((match (find-and-apply n)))
         (if match
             (cons match (loop))
             (list))))))
 
 ; INTERNAL FUNCTION: Given an AST node n, flush all attribute cache entries that depend on
 ; information of the subtree spaned by n but are outside of it.
 (define flush-depending-attribute-cache-entries-outside-of
   (lambda (n)
     (let loop ((n* n))
       (for-each
        (lambda (influence)
          (unless (node-inside-of? (attribute-instance-context (attribute-cache-entry-context (car influence))) n)
            (flush-attribute-cache-entry (car influence))))
        (node-cache-influences n*))
       (for-each
        (lambda (att)
          (vector-for-each
           (lambda (att-cache)
             (for-each
              (lambda (dependent-cache)
                (unless (node-inside-of? (attribute-instance-context (attribute-cache-entry-context dependent-cache)) n)
                  (flush-attribute-cache-entry dependent-cache)))
              (attribute-cache-entry-cache-influences att-cache)))
           (call-with-values
            (lambda ()
              (hashtable-entries (attribute-instance-cache att)))
            (lambda (key-vector value-vector)
              value-vector))))
        (node-attributes n*))
       (unless (node-terminal? n*)
         (for-each
          loop
          (node-children n*))))))
 
 (define rewrite-terminal
   (lambda (i n new-value)
     ; Before changing the value of the terminal ensure, that...
     (when (evaluator-state-in-evaluation? (node-evaluator-state n)) ; ...no attributes are in evaluation and...
       (throw-exception
        "Cannot change terminal value; "
        "There are attributes in evaluation."))
     (let ((n
            (if (symbol? i)
                (node-find-child n i)
                (and (>= i 1) (<= i (length (node-children n))) (list-ref (node-children n) (- i 1))))))
       (unless (and n (node-terminal? n)) ; ...the given context is a terminal. If so,...
         (throw-exception
          "Cannot change terminal value; "
          "The given context does not exist or is no terminal."))
       (unless (equal? (node-children n) new-value)
         (for-each ; ...flush all attribute cache entries influenced by the terminal and...
          (lambda (influence)
            (flush-attribute-cache-entry (car influence)))
          (node-cache-influences n))
         (node-children-set! n new-value))))) ; ...rewrite its value.
 
 (define rewrite-refine
   (lambda (n t . c)
     ;;; Before refining the non-terminal ensure, that...
     (when (evaluator-state-in-evaluation? (node-evaluator-state n)) ; ...non of its attributes are in evaluation,...
       (throw-exception
        "Cannot refine node; "
        "There are attributes in evaluation."))
     (when (or (node-list-node? n) (node-bud-node? n)) ; ...it is not a list or bud node,...
       (throw-exception
        "Cannot refine node; "
        "The node is a " (if (node-list-node? n) "list" "bud") " node."))
     (let* ((old-rule (node-ast-rule n))
            (new-rule (racr-specification-find-rule (ast-rule-specification old-rule) t)))
       (unless (and new-rule (ast-rule-subtype? new-rule old-rule)) ; ...the given type is a subtype,...
         (throw-exception
          "Cannot refine node; "
          t " is not a subtype of " (ast-node-type n) "."))
       (let ((additional-children (list-tail (ast-rule-production new-rule) (length (ast-rule-production old-rule)))))
         (unless (= (length additional-children) (length c)) ; ...the expected number of new children are given,...
           (throw-exception
            "Cannot refine node; "
            "Unexpected number of additional children."))
         (let ((c
                (map ; ...each child...
                 (lambda (symbol child)
                   (cond
                     ((symbol-non-terminal? symbol)
                      (unless (node? child) ; ...fits,...
                        (throw-exception
                         "Cannot refine node; "
                         "The given children do not fit."))
                      (when (node-parent child) ; ...is not part of another AST,...
                        (throw-exception
                         "Cannot refine node; "
                         "A given child already is part of another AST."))
                      (when (node-inside-of? n c) ; ...does not contain the refined node and...
                        (throw-exception
                         "Cannot refine node; "
                         "The node to refine is part of the AST spaned by a given child."))
                      (when (evaluator-state-in-evaluation? (node-evaluator-state child)) ; ...non of its attributes are in evaluation.
                        (throw-exception
                         "Cannot refine node; "
                         "There are attributes in evaluation."))
                      (if (symbol-kleene? symbol)
                          (if (node-list-node? child)
                              (for-each
                               (lambda (child)
                                 (unless
                                     (or
                                      (node-bud-node? child)
                                      (ast-rule-subtype? (node-ast-rule child) (symbol-non-terminal? symbol)))
                                   (throw-exception
                                    "Cannot refine node; "
                                    "The given children do not fit.")))
                               (node-children child))
                              (throw-exception
                               "Cannot refine node; "
                               "The given children do not fit."))
                          (unless
                              (and
                               (node-non-terminal? child)
                               (not (node-list-node? child))
                               (or (node-bud-node? child) (ast-rule-subtype? (node-ast-rule child) (symbol-non-terminal? symbol))))
                            (throw-exception
                             "Cannot refine node; "
                             "The given children do not fit.")))
                      child)
                     (else
                      (when (node? child)
                        (throw-exception
                         "Cannot refine node; "
                         "The given children do not fit."))
                      (make-node 'terminal n child))))
                 additional-children
                 c)))
           ;;; Everything is fine. Thus,...
           (for-each ; ...flush the influenced attribute cache entries, i.e., all entries influenced by the node's...
            (lambda (influence)
              (when (or
                     (and (vector-ref (cdr influence) 1) (not (null? c))) ; ...number of children,...
                     (and (vector-ref (cdr influence) 2) (not (eq? old-rule new-rule))) ; ...type,...
                     (find ; ...supertype or...
                      (lambda (t2)
                        (not (eq? (ast-rule-subtype? t2 old-rule) (ast-rule-subtype? t2 new-rule))))
                      (vector-ref (cdr influence) 3))
                     (find ; ...subtype. Afterwards,...
                      (lambda (t2)
                        (not (eq? (ast-rule-subtype? old-rule t2) (ast-rule-subtype? new-rule t2))))
                      (vector-ref (cdr influence) 4)))
                (flush-attribute-cache-entry (car influence))))
            (node-cache-influences n))
           (node-ast-rule-set! n new-rule) ; ...update the node's type,...
           (update-synthesized-attribution n) ; ...synthesized attribution,...
           (node-children-set! n (append (node-children n) c (list))) ; ...insert the new children,...
           (for-each
            (lambda (child)
              (node-parent-set! child n)
              (distribute-evaluator-state (node-evaluator-state n) child)) ; ...update their evaluator state and...
            c)
           (for-each ; ...update the inherited attribution of all children.
            update-inherited-attribution
            (node-children n)))))))
 
 (define rewrite-abstract
   (lambda (n t)
     ;;; Before abstracting the non-terminal ensure, that...
     (when (evaluator-state-in-evaluation? (node-evaluator-state n)) ; ...no attributes are in evaluation,...
       (throw-exception
        "Cannot abstract node; "
        "There are attributes in evaluation."))
     (when (or (node-list-node? n) (node-bud-node? n)) ; ...the given node is not a list or bud node and...
       (throw-exception
        "Cannot abstract node; "
        "The node is a " (if (node-list-node? n) "list" "bud") " node."))
     (let* ((old-rule (node-ast-rule n))
            (new-rule (racr-specification-find-rule (ast-rule-specification old-rule) t))
            (num-new-children (- (length (ast-rule-production new-rule)) 1)))
       (unless (and new-rule (ast-rule-subtype? old-rule new-rule)) ; ...the given type is a supertype.
         (throw-exception
          "Cannot abstract node; "
          t " is not a supertype of " (ast-node-type n) "."))
       ;;; Everything is fine. Thus,...
       (let ((children-to-remove (list-tail (node-children n) num-new-children)))
         (for-each ; ...flush all influenced attribute cache entries, i.e., (1) all entries influenced by the node's...
          (lambda (influence)
            (when (or
                   (and (vector-ref (cdr influence) 1) (not (null? children-to-remove))) ; ...number of children,...
                   (and (vector-ref (cdr influence) 2) (not (eq? old-rule new-rule))) ; ...type...
                   (find ; ...supertype or...
                    (lambda (t2)
                      (not (eq? (ast-rule-subtype? t2 old-rule) (ast-rule-subtype? t2 new-rule))))
                    (vector-ref (cdr influence) 3))
                   (find ; ...subtype and...
                    (lambda (t2)
                      (not (eq? (ast-rule-subtype? old-rule t2) (ast-rule-subtype? new-rule t2))))
                    (vector-ref (cdr influence) 4)))
              (flush-attribute-cache-entry (car influence))))
          (node-cache-influences n))
         (for-each ; ...(2) all entries depending on, but still outside of, an removed AST. Afterwards,...
          flush-depending-attribute-cache-entries-outside-of
          children-to-remove)
         (node-ast-rule-set! n new-rule) ; ...update the node's type and...
         (update-synthesized-attribution n) ; ...synthesized attribution and...
         (for-each ; ...for every child to remove,...
          (lambda (child)
            (detach-inherited-attributes child) ; ...delete its inherited attribution,...
            (node-parent-set! child #f) ; ...detach it from the AST and...
            (distribute-evaluator-state (make-evaluator-state) child)) ; ...update its evaluator state. Further,...
          children-to-remove)
         (unless (null? children-to-remove)
           (if (> num-new-children 0)
               (set-cdr! (list-tail (node-children n) (- num-new-children 1)) (list))
               (node-children-set! n (list))))
         (for-each ; ...update the inherited attribution of all remaining children. Finally,...
          update-inherited-attribution
          (node-children n))
         children-to-remove)))) ; ...return the removed children.
 
 (define rewrite-add
   (lambda (l e)
     ;;; Before adding the element ensure, that...
     (when (or ; ...no attributes are in evaluation,...
            (evaluator-state-in-evaluation? (node-evaluator-state l))
            (evaluator-state-in-evaluation? (node-evaluator-state e)))
       (throw-exception
        "Cannot add list element; "
        "There are attributes in evaluation."))
     (unless (node-list-node? l) ; ...indeed a list-node is given as context,...
       (throw-exception
        "Cannot add list element; "
        "The given context is no list-node."))
     (when (node-parent e) ; ...the new element is not part of another AST,...
       (throw-exception
        "Cannot add list element; "
        "The element to add already is part of another AST."))
     (when (node-inside-of? l e) ; ...its spaned AST does not contain the list-node and...
       (throw-exception
        "Cannot add list element; "
        "The given list is part of the AST spaned by the element to add."))
     (when (node-parent l)
       (let ((expected-type
              (symbol-non-terminal?
               (list-ref
                (ast-rule-production (node-ast-rule (node-parent l)))
                (node-child-index l)))))
         (unless (or (node-bud-node? e) (ast-rule-subtype? (node-ast-rule e) expected-type)) ; ...it can be a child of the list-node.
           (throw-exception
            "Cannot add list element; "
            "The new element does not fit."))))
     ;;; When all rewrite constraints are satisfied,...
     (for-each ; ...flush all attribute cache entries influenced by the list-node's number of children,...
      (lambda (influence)
        (when (vector-ref (cdr influence) 1)
          (flush-attribute-cache-entry (car influence))))
      (node-cache-influences l))
     (node-children-set! l (append (node-children l) (list e))) ; ...add the new element,...
     (node-parent-set! e l)
     (distribute-evaluator-state (node-evaluator-state l) e) ; ...initialize its evaluator state and...
     (when (node-parent l)
       (update-inherited-attribution e)))) ; ...any inherited attributes defined for its new context.
 
 (define rewrite-subtree
   (lambda (old-fragment new-fragment)
     ;;; Before replacing the subtree ensure, that...
     (when (or  ; ...no attributes are in evaluation,...
            (evaluator-state-in-evaluation? (node-evaluator-state old-fragment))
            (evaluator-state-in-evaluation? (node-evaluator-state new-fragment)))
       (throw-exception
        "Cannot replace subtree; "
        "There are attributes in evaluation."))
     (unless (and (node? new-fragment) (node-non-terminal? new-fragment)) ; ...the new fragment is a non-terminal node,...
       (throw-exception
        "Cannot replace subtree; "
        "The replacement is not a non-terminal node."))
     (when (node-parent new-fragment) ; ...it is not part of another AST...
       (throw-exception
        "Cannot replace subtree; "
        "The replacement already is part of another AST."))
     (when (node-inside-of? old-fragment new-fragment) ; ...its spaned AST does not contain the old-fragment and...
       (throw-exception
        "Cannot replace subtree; "
        "The given old fragment is part of the AST spaned by the replacement."))
     (let* ((n* (if (node-list-node? (node-parent old-fragment)) (node-parent old-fragment) old-fragment))
            (expected-type
             (symbol-non-terminal?
              (list-ref
               (ast-rule-production (node-ast-rule (node-parent n*)))
               (node-child-index n*)))))
       (if (node-list-node? old-fragment) ; ...it fits into its new context.
           (if (node-list-node? new-fragment)
               (for-each
                (lambda (element)
                  (unless (or (node-bud-node? element) (ast-rule-subtype? (node-ast-rule element) expected-type))
                    (throw-exception
                     "Cannot replace subtree; "
                     "The replacement does not fit.")))
                (node-children new-fragment))
               (throw-exception
                "Cannot replace subtree; "
                "The replacement does not fit."))
           (unless (and
                    (not (node-list-node? new-fragment))
                    (or (node-bud-node? new-fragment) (ast-rule-subtype? (node-ast-rule new-fragment) expected-type)))
             (throw-exception
              "Cannot replace subtree; "
              "The replacement does not fit."))))
     ;;; When all rewrite constraints are satisfied,...
     (detach-inherited-attributes old-fragment) ; ...delete the old fragment's inherited attribution,...
     ; ...flush all attribute cache entries depending on it and outside its spaned tree,...
     (flush-depending-attribute-cache-entries-outside-of old-fragment)
     (distribute-evaluator-state (node-evaluator-state old-fragment) new-fragment) ; ...update both fragments' evaluator state,...
     (distribute-evaluator-state (make-evaluator-state) old-fragment)
     (set-car! ; ...replace the old fragment by the new one and...
      (list-tail (node-children (node-parent old-fragment)) (- (node-child-index old-fragment) 1))
      new-fragment)
     (node-parent-set! new-fragment (node-parent old-fragment))
     (node-parent-set! old-fragment #f)
     (update-inherited-attribution new-fragment) ; ...update the new fragment's inherited attribution. Finally,...
     old-fragment )) ; ...return the removed old fragment.
 
 (define rewrite-insert
   (lambda (l i e)
     ;;; Before inserting the element ensure, that...
     (when (or ; ...no attributes are in evaluation,...
            (evaluator-state-in-evaluation? (node-evaluator-state l))
            (evaluator-state-in-evaluation? (node-evaluator-state e)))
       (throw-exception
        "Cannot insert list element; "
        "There are attributes in evaluation."))
     (unless (node-list-node? l) ; ...indeed a list-node is given as context,...
       (throw-exception
        "Cannot insert list element; "
        "The given context is no list-node."))
     (when (or (< i 1) (> i (+ (length (node-children l)) 1))) ; ...the list has enough elements,...
       (throw-exception
        "Cannot insert list element; "
        "The given index is out of range."))
     (when (node-parent e) ; ...the new element is not part of another AST,...
       (throw-exception
        "Cannot insert list element; "
        "The element to insert already is part of another AST."))
     (when (node-inside-of? l e) ; ...its spaned AST does not contain the list-node and...
       (throw-exception
        "Cannot insert list element; "
        "The given list is part of the AST spaned by the element to insert."))
     (when (node-parent l)
       (let ((expected-type
              (symbol-non-terminal?
               (list-ref
                (ast-rule-production (node-ast-rule (node-parent l)))
                (node-child-index l)))))
         (unless (or (node-bud-node? e) (ast-rule-subtype? (node-ast-rule e) expected-type)) ; ...it can be a child of the list-node.
           (throw-exception
            "Cannot insert list element; "
            "The new element does not fit."))))
     ;;; When all rewrite constraints are satisfied...
     (for-each ; ...flush all attribute cache entries influenced by the list-node's number of children. Further,...
      (lambda (influence)
        (when (vector-ref (cdr influence) 1)
          (flush-attribute-cache-entry (car influence))))
      (node-cache-influences l))
     (for-each ; ...for each tree spaned by the successor element's of the insertion position,...
      ; ...flush all attribute cache entries depending on, but still outside of, the respective tree. Then,...
      flush-depending-attribute-cache-entries-outside-of
      (list-tail (node-children l) (- i 1)))
     (node-children-set! ; ...insert the new element,...
      l
      (let loop ((l (node-children l)) (i i))
        (cond
          ((= i 1) (cons e (loop l 0)))
          ((null? l) (list))
          (else (cons (car l) (loop (cdr l) (- i 1)))))))
     (node-parent-set! e l)
     (distribute-evaluator-state (node-evaluator-state l) e) ; ...initialize its evaluator state and...
     (when (node-parent l)
       (update-inherited-attribution e)))) ; ...any inherited attributes defined for its new context.
 
 (define rewrite-delete
   (lambda (n)
     ;;; Before deleting the element ensure, that...
     (when (evaluator-state-in-evaluation? (node-evaluator-state n)) ; ...no attributes are in evaluation and...
       (throw-exception
        "Cannot delete list element; "
        "There are attributes in evaluation."))
     (unless (and (node-parent n) (node-list-node? (node-parent n))) ; ...the given node is a list-node element.
       (throw-exception
        "Cannot delete list element; "
        "The given node is not element of a list."))
     ;;; When all rewrite constraints are satisfied, flush all attribute cache entries influenced by
     ; the number of children of the list-node the element is part of. Further,...
     (for-each
      (lambda (influence)
        (when (vector-ref (cdr influence) 1)
          (flush-attribute-cache-entry (car influence))))
      (node-cache-influences (node-parent n)))
     (detach-inherited-attributes n) ; ...delete the element's inherited attributes and,...
     (for-each ; ...for each tree spaned by the element and its successor elements,...
      ; ...flush all attributes cache entries depending on, but still outside of, the respective tree. Then,...
      flush-depending-attribute-cache-entries-outside-of
      (list-tail (node-children (node-parent n)) (- (node-child-index n) 1)))
     (node-children-set! (node-parent n) (remq n (node-children (node-parent n)))) ; ...remove the element from the list,...
     (node-parent-set! n #f)
     (distribute-evaluator-state (make-evaluator-state) n) ; ...reset its evaluator state and...
     n)) ; ...return it.
 
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Dependency Tracking Support ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
 
 ; INTERNAL FUNCTION: Given an attribute instance, flush all its cache entries.
 (define flush-attribute-instance
   (lambda (att)
     (call-with-values
      (lambda ()
        (hashtable-entries (attribute-instance-cache att)))
      (lambda (keys values)
        (vector-for-each
         flush-attribute-cache-entry
         values)))))
 
 ; INTERNAL FUNCTION: Given an attribute cache entry, delete it and all depending entries.
 (define flush-attribute-cache-entry
   (lambda (att-cache)
     (let ((influenced-caches (attribute-cache-entry-cache-influences att-cache))) ; Save all influenced attribute cache entries.
       ; Delete foreign influences:
       (for-each ; For every cache entry I the entry depends on,...
        (lambda (influencing-cache)
          (attribute-cache-entry-cache-influences-set! ; ...remove the influence edge from I to the entry.
           influencing-cache
           (remq att-cache (attribute-cache-entry-cache-influences influencing-cache))))
        (attribute-cache-entry-cache-dependencies att-cache))
       (for-each ; For every node N the attribute cache entry depends on...
        (lambda (node-dependency)
          (node-cache-influences-set!
           (car node-dependency)
           (remp ; ...remove the influence edge from N to the entry.
            (lambda (cache-influence)
              (eq? (car cache-influence) att-cache))
            (node-cache-influences (car node-dependency)))))
        (attribute-cache-entry-node-dependencies att-cache))
       ; Delete the attribute cache entry:
       (hashtable-delete!
        (attribute-instance-cache (attribute-cache-entry-context att-cache))
        (attribute-cache-entry-arguments att-cache))
       (attribute-cache-entry-cache-dependencies-set! att-cache (list))
       (attribute-cache-entry-node-dependencies-set! att-cache (list))
       (attribute-cache-entry-cache-influences-set! att-cache (list))
       ; Proceed flushing, i.e., for every attribute cache entry D the entry originally influenced,...
       (for-each
        (lambda (dependent-cache)
          (flush-attribute-cache-entry dependent-cache)) ; ...flush D.
        influenced-caches))))
 
 ; INTERNAL FUNCTION: See "add-dependency:cache->node-characteristic".
 (define add-dependency:cache->node
   (lambda (influencing-node)
     (add-dependency:cache->node-characteristic influencing-node (cons 0 racr-nil))))
 
 ; INTERNAL FUNCTION: See "add-dependency:cache->node-characteristic".
 (define add-dependency:cache->node-num-children
   (lambda (influencing-node)
     (add-dependency:cache->node-characteristic influencing-node (cons 1 racr-nil))))
 
 ; INTERNAL FUNCTION: See "add-dependency:cache->node-characteristic".
 (define add-dependency:cache->node-type
   (lambda (influencing-node)
     (add-dependency:cache->node-characteristic influencing-node (cons 2 racr-nil))))
 
 ; INTERNAL FUNCTION: See "add-dependency:cache->node-characteristic".
 (define add-dependency:cache->node-super-type
   (lambda (influencing-node comparision-type)
     (add-dependency:cache->node-characteristic influencing-node (cons 3 comparision-type))))
 
 ; INTERNAL FUNCTION: See "add-dependency:cache->node-characteristic".
 (define add-dependency:cache->node-sub-type
   (lambda (influencing-node comparision-type)
     (add-dependency:cache->node-characteristic influencing-node (cons 4 comparision-type))))
 
 ; INTERNAL FUNCTION: Given a node N and a correlation C add an dependency-edge marked with C from
 ; the attribute cache entry currently in evaluation (considering the evaluator state of the AST N
 ; is part of) to N and an influence-edge vice versa. If no attribute cache entry is in evaluation
 ; no edges are added. The following six correlations exist:
 ;  1) Dependency on the existence of the node (i.e., existence of a node at the same location)
 ;  2) Dependency on the node's number of children (i.e., existence of a node at the same location and with
 ;     the same number of children)
 ;  3) Dependency on the node's type (i.e., existence of a node at the same location and with the same type)
 ;  4) Dependency on whether the node's type is a supertype w.r.t. a certain type encoded in C or not
 ;  5) Dependency on whether the node's type is a subtype w.r.t. a certain type encoded in C or not
 (define add-dependency:cache->node-characteristic
   (lambda (influencing-node correlation)
     (let ((dependent-cache (evaluator-state-in-evaluation? (node-evaluator-state influencing-node))))
       (when dependent-cache
         (let ((dependency-vector
                (let ((dc-hit (assq influencing-node (attribute-cache-entry-node-dependencies dependent-cache))))
                  (and dc-hit (cdr dc-hit)))))
           (unless dependency-vector
             (set! dependency-vector (vector #f #f #f (list) (list)))
             (attribute-cache-entry-node-dependencies-set!
              dependent-cache
              (cons
               (cons influencing-node dependency-vector)
               (attribute-cache-entry-node-dependencies dependent-cache)))
             (node-cache-influences-set!
              influencing-node
              (cons
               (cons dependent-cache dependency-vector)
               (node-cache-influences influencing-node))))
           (let ((correlation-type (car correlation))
                 (correlation-arg (cdr correlation)))
             (vector-set!
              dependency-vector
              correlation-type
              (case correlation-type
                ((0 1 2)
                 #t)
                ((3 4)
                 (let ((known-args (vector-ref dependency-vector correlation-type)))
                   (if (memq correlation-arg known-args)
                       known-args
                       (cons correlation-arg known-args))))))))))))
 
 ; INTERNAL FUNCTION: Given an attribute cache entry C, add an dependency-edge from C to the entry currently
 ; in evaluation (considering the evaluator state of the AST C is part of) and an influence-edge vice-versa.
 ; If no attribute cache entry is in evaluation no edges are added.
 (define add-dependency:cache->cache
   (lambda (influencing-cache)
     (let ((dependent-cache
            (evaluator-state-in-evaluation?
             (node-evaluator-state
              (attribute-instance-context
               (attribute-cache-entry-context influencing-cache))))))
       (when (and dependent-cache (not (memq influencing-cache (attribute-cache-entry-cache-dependencies dependent-cache))))
         (attribute-cache-entry-cache-dependencies-set!
          dependent-cache
          (cons
           influencing-cache
           (attribute-cache-entry-cache-dependencies dependent-cache)))
         (attribute-cache-entry-cache-influences-set!
          influencing-cache
          (cons
           dependent-cache
           (attribute-cache-entry-cache-influences influencing-cache))))))))