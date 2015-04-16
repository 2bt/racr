; This program and the accompanying materials are made available under the
; terms of the MIT license (X11 license) which accompanies this distribution.

; Author: C. Bürger

#!r6rs

(library
 (atomic-petrinets user-interface)
 (export initialise-petrinet-language petrinet: transition: =p-lookup =t-lookup
         fire-transition! run-petrinet! interpret-petrinet!
         petrinets-exception? assert-marking assert-enabled)
 (import (rnrs) (rnrs mutable-pairs) (racr core) (racr testing)
         (atomic-petrinets query-support)
         (atomic-petrinets ast-scheme)
         (atomic-petrinets name-analysis)
         (atomic-petrinets well-formedness-analysis)
         (atomic-petrinets enabled-analysis)
         (atomic-petrinets execution-semantics))
 
 ;;; Syntax:
 
 (define-syntax petrinet:
   (syntax-rules ()
     ((_ ((place start-marking ...) ...)
         transition ... )
      (let ((net
             (:AtomicPetrinet
              (list (:Place 'place (:Token start-marking) ...)
                    ...)
              (list transition
                    ...))))
        (unless (=valid? net)
          (exception: "Cannot construct Petri net; The net is not well-formed."))
        net))))
 
 (define-syntax transition:
   (syntax-rules ()
     ((_ name
         ((input-place (variable matching-condition) ...) ...)
         ((output-place to-produce ...) ...))
      (:Transition
       'name
       (list (:Arc
              'input-place
              (list (lambda (variable) matching-condition) ...))
             ...)
       (list (:Arc
              'output-place
              (lambda (variable ... ...) (list to-produce ...)))
             ...)))))
 
 ;;; REPL Interpreter:
 
 (define (interpret-petrinet! net)
   (unless (=valid? net)
     (exception: "Cannot interpret Petri Net; The given net is not well-formed."))
   (display "Marking:\n")
   (map
    (lambda (n)
      (display "  ") (display (->name n)) (display ": ")
      (display (map ->value (->* (->Token* n)))) (display "\n"))
    (=places net))
   (display "Enabled:\n  ")
   (display (map ->name (filter =enabled? (=transitions net)))) (display "\n")
   (let ((input? (read)))
     (when (and input? (not (eof-object? input?)))
       (let ((to-fire? (=t-lookup net input?)))
         (unless to-fire?
           (exception: "Cannot interpret Petri Net; Undefined transition to execute."))
         (display "Fire:\n  ") (display (->name to-fire?)) (display "\n")
         (fire-transition! to-fire?)
         (interpret-petrinet! net)))))
 
 ;;; Testing:
 
 (define (assert-marking net . marking) ; Each marking is a list of a place followed by its tokens.
   (define marked (map (lambda (m) (=p-lookup net (car m))) marking))
   (define marked-marking (map cdr marking))
   (define !marked (filter (lambda (n) (not (memq n marked))) (=places net)))
   (define !marked-marking (map (lambda (n) (list)) !marked))
   (define (check-place place expected-tokens)
     (define given-values (map ->value (->* (->Token* place))))
     (define-record-type nil-record (sealed #t)(opaque #t))
     (define Ok (make-nil-record))
     (for-each
      (lambda (expected-token)
        (let ((value-found? (member expected-token given-values)))
          (assert value-found?)
          (set-car! value-found? Ok)))
      expected-tokens)
     (assert (for-all nil-record? given-values)))
   (for-each check-place marked marked-marking)
   (for-each check-place !marked !marked-marking))
 
 (define (assert-enabled net . enabled)
   (define t-enabled (map (lambda (t) (=t-lookup net t)) enabled))
   (define t-!enabled (filter (lambda (t) (not (memq t t-enabled))) (=transitions net)))
   (assert (for-all =enabled? t-enabled))
   (assert (for-all (lambda (t) (not (=enabled? t))) t-!enabled))
   (assert-exception petrinets-exception? (for-all fire-transition! t-!enabled)))
 
 ;;; Initialisation:
 
 (define (initialise-petrinet-language)
   (when (= (specification->phase pn) 1)
     (specify-ast)
     (compile-ast-specifications pn 'AtomicPetrinet)
     (specify-query-support)
     (specify-name-analysis)
     (specify-well-formedness-analysis)
     (specify-enabled-analysis)
     (specify-execution-semantics)
     (compile-ag-specifications pn))))