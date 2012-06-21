; This program and the accompanying materials are made available under the
; terms of the MIT license (X11 license) which accompanies this distribution.

; Author: C. Bürger

#!r6rs

(library
 (siple access-support)
 (export
  specify-access-support)
 (import (rnrs) (racr) (siple ast))
 
 (define specify-access-support
   (lambda ()
     (with-specification
      siple-specification
      
      (ag-rule
       dewey-address
       (CompilationUnit
        0
        (lambda (n)
          (list 1)))
       (Statement
        0
        (lambda (n)
          (append
           (att-value 'dewey-address (ast-parent n))
           (if (ast-list-node? (ast-parent n))
               (list (ast-child-index (ast-parent n)))
               (list))
           (list (ast-child-index n))))))
      
      (ag-rule
       is-procedure-body
       (Block
        1
        (lambda (n)
          #f))
       (ProcedureDeclaration
        4
        (lambda (n)
          (ast-parent n))))
      
      (ag-rule
       procedure-in-context
       (CompilationUnit
        0
        (lambda (n)
          #f))
       (ProcedureDeclaration
        4
        (lambda (n)
          (ast-parent n))))
      
      (ag-rule
       as-boolean
       (Constant
        0
        (lambda (n)
          (let ((lexem (ast-child 'lexem n)))
            (cond
              ((string=? lexem "true") #t)
              ((string=? lexem "false") #f)
              (else 'siple:nil))))))
      
      (ag-rule
       as-number
       (Constant
        0
        (lambda (n)
          (let ((number (string->number (ast-child 'lexem n))))
            (if number number 'siple:nil)))))
      
      (ag-rule
       as-integer
       (Constant
        0
        (lambda (n)
          (if (not (find
                    (lambda (c) (char=? c #\.))
                    (string->list (ast-child 'lexem n))))
              (att-value 'as-number n)
              'siple:nil))))
      
      (ag-rule
       as-real
       (Constant
        0
        (lambda (n)
          (if (find
               (lambda (c) (char=? c #\.))
               (string->list (ast-child 'lexem n)))
              (att-value 'as-number n)
              'siple:nil))))))))