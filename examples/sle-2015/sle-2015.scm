; This program and the accompanying materials are made available under the
; terms of the MIT license (X11 license) which accompanies this distribution.

; Author: C. Bürger

#!r6rs

(import (rnrs) (racr core) (racr testing))

(define language              (create-specification))

; AST Accessors:
(define (->DErr n)            (ast-child 'DErr n))
(define (->Stmt* n)           (ast-child 'Stmt* n))
(define (->Op1 n)             (ast-child 'Op1 n))
(define (->Op2 n)             (ast-child 'Op2 n))
(define (->name n)            (ast-child 'name n))
(define (->type n)            (ast-child 'type n))
(define (<- n)                (ast-parent n))
(define (->* n)               (ast-children n))
(define (index n)             (ast-child-index n))

; Attribute Accessors:
(define (L-Decl n name)       (att-value 'L-Decl n name))
(define (G-Decl n name)       (att-value 'G-Decl n name))
(define (Type n)              (att-value 'Type n))
(define (Well-formed? n)      (att-value 'Well-formed? n))
(define (Needs-coercion? n)   (att-value 'Needs-coercion? n))
(define (Superfluous-cast? n) (att-value 'Superfluous-cast? n))

; Type Support & Support Functions:
(define (=? e1 e2)            (equal? e1 e2))
(define Integer               (list 'Integer))
(define Real                  (list 'Real))
(define Error-Type            (list 'Error-Type))
(define (valid-type! t)
  (if (memq t (list Integer Real)) t (raise "Unknown type.")))

; AST Constructors:
(define (Prog . s)
  (create-ast language 'Prog (list (create-ast-list s) (DErr))))
(define (DErr)
  (create-ast language 'DErr (list)))
(define (Block . s)
  (create-ast language 'Block (list (create-ast-list s))))
(define (Decl type name)
  (create-ast language 'Decl (list (valid-type! type) name)))
(define (Use name)
  (create-ast language 'Use (list name)))
(define (Cast type op1)
  (create-ast language 'Cast (list (valid-type! type) op1)))
(define (BiOp op1 op2)
  (create-ast language 'BiOp (list op1 op2)))
(define (Use? n)
  (and (not (ast-list-node? n)) (=? (ast-node-type n) 'Use)))

;;; Abstract Syntax Tree Scheme:

(with-specification
 language
 
 (ast-rule 'Prog->Stmt*-DErr)
 (ast-rule 'DErr->)
 (ast-rule 'Stmt->)
 (ast-rule 'Block:Stmt->Stmt*)
 (ast-rule 'Decl:Stmt->type-name)
 (ast-rule 'Expr:Stmt->)
 (ast-rule 'Use:Expr->name)
 (ast-rule 'Cast:Expr->type-Expr<Op1)
 (ast-rule 'BiOp:Expr->Expr<Op1-Expr<Op2)
 
 (compile-ast-specifications 'Prog))

;;; Name & Type Analyses:

(with-specification
 language
 
 ; Semantics of (find-L-Decl name l i): First element e of
 ;  list l with index <= i and (L-Decl e name), otherwise #f.
 (define (find-L-Decl name l i)
   (ast-find-child
    (lambda (i e) (L-Decl e name))
    l
    (cons 1 i)))
 
 (ag-rule
  G-Decl ; Inherited attribute
  ((Block Stmt*) ; Equation for the statements of blocks
   (lambda (n name)
     (or (find-L-Decl name (<- n) (index n))
         (G-Decl (<- (<- n)) name))))
  ((Prog Stmt*) ; Equation for the statements of programs
   (lambda (n name)
     (or (find-L-Decl name (<- n) (index n))
         (->DErr (<- (<- n)))))))
 
 (ag-rule
  L-Decl ; Synthesised attribute
  (Stmt (lambda (n name) #f))
  (Decl (lambda (n name) (if (=? (->name n) name) n #f))))
 
 (ag-rule
  Type ; Synthesised attribute
  (Use  (lambda (n) (Type (G-Decl n (->name n)))))
  (Decl (lambda (n) (->type n)))
  (DErr (lambda (n) Error-Type)))
 
 (ag-rule
  Well-formed? ; Synthesised attribute
  (Use  (lambda (n) (not (=? (Type n) Error-Type))))
  (Decl (lambda (n) (=? (G-Decl n (->name n)) n))))
 
 (ag-rule
  Type
  (Cast (lambda (n) (->type n)))
  (BiOp (lambda (n) (Type (->Op1 n))))))

;;; Type Coercion:

(with-specification
 language
 
 (ag-rule
  Needs-coercion?
  (Prog (lambda (n) #f))
  ((Cast Op1)
   (lambda (n) #f))
  ((BiOp Op1)
   (lambda (n)
     (and (=? (Type n) Integer)
          (=? (Type (->Op2 (<- n))) Real))))
  ((BiOp Op2)
   (lambda (n)
     (and (=? (Type n) Integer)
          (=? (Type (->Op1 (<- n))) Real))))))

(define (cast-to-real n)
  (let ((dummy-node (create-ast-bud)))
    (rewrite-subtree n dummy-node)
    (rewrite-subtree dummy-node (Cast Real n))))

;;; Superfluous Type Casts Optimisation:

(with-specification
 language
 
 (ag-rule
  Superfluous-cast?
  (Prog (lambda (n) #f))
  (Stmt (lambda (n) #f))
  (Cast (lambda (n) (=? (Type n) (Type (->Op1 n)))))))

(define (delete-cast n)
  (let ((op1 (->Op1 n)))
    (rewrite-subtree op1 (create-ast-bud))
    (rewrite-subtree n op1)))

;;; Program normalisation:

(define (normalise-program n)
  (let ((trans1
         (lambda (n)
           (and (Needs-coercion? n)
                (cast-to-real n))))
        (trans2
         (lambda (n)
           (and (Superfluous-cast? n)
                (delete-cast n)))))
    (perform-rewrites n 'top-down trans1 trans2)))

;;; Type Refactoring:

(define (change-type n type)
  (when (Well-formed? n)
    (rewrite-terminal
     'type (G-Decl n (->name n)) type)))

(define (change-types n type)
  (define (process-subtree n)
    (when (ast-node? n)
      (if (Use? n)
          (change-type n type)
          (for-each process-subtree (->* n)))))
  (process-subtree n))

;;; Load Language & User Interface:

(compile-ag-specifications language)

(define (display-ast ast)
  (define (print name) (cons name (lambda (v) v)))
  (define printer
    (list (print 'Needs-coercion?) (print 'Well-formed?)
          (print 'Superfluous-cast?) (print 'Type)))
  (print-ast ast printer (current-output-port)))